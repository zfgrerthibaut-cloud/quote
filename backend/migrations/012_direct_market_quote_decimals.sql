BEGIN;

ALTER TABLE direct_market_launch_facts
  ADD COLUMN IF NOT EXISTS quote_decimals smallint CHECK (quote_decimals IS NULL OR quote_decimals BETWEEN 0 AND 36);

COMMENT ON COLUMN direct_market_launch_facts.quote_decimals IS
  'Quote token decimals emitted by the direct engine launch event. Nullable only for pre-012 historical ABIs.';

CREATE OR REPLACE FUNCTION apply_direct_market_valuation(
  target_chain_id bigint,
  target_engine bytea,
  target_launch_id numeric
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  direct_row direct_market_launch_facts%ROWTYPE;
  attestation_row quote_price_attestation_facts%ROWTYPE;
  attestation_found boolean;
BEGIN
  SELECT * INTO direct_row
  FROM direct_market_launch_facts
  WHERE chain_id = target_chain_id
    AND engine = target_engine
    AND launch_id = target_launch_id
    AND canonical
  ORDER BY block_number DESC, tx_index DESC, log_index DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  SELECT * INTO attestation_row
  FROM quote_price_attestation_facts
  WHERE chain_id = target_chain_id
    AND digest = direct_row.attestation_digest
    AND consumer = direct_row.engine
    AND creator = direct_row.creator
    AND quote_token = direct_row.quote_token
    AND price_usd_wad = direct_row.quote_price_usd_wad
    AND canonical
  ORDER BY block_number DESC, tx_index DESC, log_index DESC
  LIMIT 1;
  attestation_found := FOUND;

  UPDATE markets AS market
  SET
    deposited_supply = direct_row.deposited_supply,
    direct_position_token_id = direct_row.position_token_id,
    target_fdv_usd_wad = direct_row.target_fdv_usd_wad,
    quote_price_usd_wad = direct_row.quote_price_usd_wad,
    quote_price_observed_at = CASE WHEN attestation_found THEN attestation_row.observation_timestamp ELSE market.quote_price_observed_at END,
    quote_price_attested_deadline = CASE WHEN attestation_found THEN attestation_row.attestation_deadline ELSE market.quote_price_attested_deadline END,
    quote_price_liquidity_usd_wad = CASE WHEN attestation_found THEN attestation_row.liquidity_usd_wad ELSE market.quote_price_liquidity_usd_wad END,
    quote_reference_token = CASE WHEN attestation_found THEN attestation_row.reference_token ELSE market.quote_reference_token END,
    quote_reference_pool = CASE WHEN attestation_found THEN attestation_row.reference_pool ELSE market.quote_reference_pool END,
    quote_price_attestation_digest = direct_row.attestation_digest,
    quote_decimals = COALESCE(
      direct_row.quote_decimals,
      market.quote_decimals,
      (
        SELECT quote_meta.decimals
        FROM token_metadata AS quote_meta
        WHERE quote_meta.chain_id = market.chain_id
          AND quote_meta.token_address = market.quote_token
        LIMIT 1
      )
    ),
    initial_sqrt_price_x96 = direct_row.sqrt_price_x96,
    tick_lower = direct_row.tick_lower,
    tick_upper = direct_row.tick_upper,
    pool_fee = direct_row.fee_tier,
    market_cap_usd = quote_wad_to_usd(direct_row.target_fdv_usd_wad),
    updated_at = now()
  WHERE market.chain_id = direct_row.chain_id
    AND market.engine = direct_row.engine
    AND market.launch_id = direct_row.launch_id
    AND market.creator = direct_row.creator
    AND market.token = direct_row.token
    AND market.quote_token = direct_row.quote_token
    AND market.market = direct_row.pool
    AND market.engine_kind = 1;
END;
$$;

COMMIT;
