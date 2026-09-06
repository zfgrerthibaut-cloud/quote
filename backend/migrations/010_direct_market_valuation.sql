BEGIN;

ALTER TABLE markets
  ADD COLUMN IF NOT EXISTS engine bytea CHECK (engine IS NULL OR octet_length(engine) = 20),
  ADD COLUMN IF NOT EXISTS requested_supply numeric(78,0) CHECK (requested_supply IS NULL OR requested_supply > 0),
  ADD COLUMN IF NOT EXISTS deposited_supply numeric(78,0) CHECK (deposited_supply IS NULL OR deposited_supply > 0),
  ADD COLUMN IF NOT EXISTS direct_position_token_id numeric(78,0) CHECK (direct_position_token_id IS NULL OR direct_position_token_id > 0),
  ADD COLUMN IF NOT EXISTS target_fdv_usd_wad numeric(78,0) CHECK (target_fdv_usd_wad IS NULL OR target_fdv_usd_wad > 0),
  ADD COLUMN IF NOT EXISTS quote_price_usd_wad numeric(78,0) CHECK (quote_price_usd_wad IS NULL OR quote_price_usd_wad > 0),
  ADD COLUMN IF NOT EXISTS quote_price_observed_at timestamptz,
  ADD COLUMN IF NOT EXISTS quote_price_attested_deadline timestamptz,
  ADD COLUMN IF NOT EXISTS quote_price_liquidity_usd_wad numeric(78,0) CHECK (quote_price_liquidity_usd_wad IS NULL OR quote_price_liquidity_usd_wad >= 0),
  ADD COLUMN IF NOT EXISTS quote_reference_token bytea CHECK (quote_reference_token IS NULL OR octet_length(quote_reference_token) = 20),
  ADD COLUMN IF NOT EXISTS quote_reference_pool bytea CHECK (quote_reference_pool IS NULL OR octet_length(quote_reference_pool) = 20),
  ADD COLUMN IF NOT EXISTS quote_price_attestation_digest bytea CHECK (quote_price_attestation_digest IS NULL OR octet_length(quote_price_attestation_digest) = 32),
  ADD COLUMN IF NOT EXISTS quote_decimals smallint CHECK (quote_decimals IS NULL OR quote_decimals BETWEEN 0 AND 36),
  ADD COLUMN IF NOT EXISTS initial_sqrt_price_x96 numeric(78,0) CHECK (initial_sqrt_price_x96 IS NULL OR initial_sqrt_price_x96 > 0),
  ADD COLUMN IF NOT EXISTS tick_lower integer,
  ADD COLUMN IF NOT EXISTS tick_upper integer,
  ADD COLUMN IF NOT EXISTS pool_fee integer CHECK (pool_fee IS NULL OR pool_fee BETWEEN 1 AND 1000000);

UPDATE markets
SET requested_supply = supply
WHERE requested_supply IS NULL;

CREATE INDEX IF NOT EXISTS markets_direct_engine_launch
  ON markets(chain_id, engine, launch_id)
  WHERE engine_kind = 1 AND engine IS NOT NULL;
CREATE INDEX IF NOT EXISTS markets_direct_quote
  ON markets(chain_id, quote_token, market_cap_usd DESC NULLS LAST, launch_id DESC)
  WHERE engine_kind = 1;
CREATE INDEX IF NOT EXISTS markets_quote_price_staleness
  ON markets(chain_id, quote_price_observed_at DESC NULLS LAST)
  WHERE quote_price_usd_wad IS NOT NULL;

COMMENT ON COLUMN markets.market_cap_usd IS
  'Launch-time target FDV or projection cache only. /v1/markets recalculates direct market cap from canonical Pancake V3 swaps when a swap exists.';
COMMENT ON COLUMN markets.quote_price_usd_wad IS
  'Backend-signed quote-token USD observation consumed at launch. This is an as-of observation, not a live oracle price.';
COMMENT ON COLUMN markets.quote_price_observed_at IS
  'Timestamp inside the consumed quote-price attestation. Treat USD conversions as stale outside this launch-time context.';

CREATE TABLE IF NOT EXISTS quote_price_attestation_facts (
  chain_id bigint NOT NULL CHECK (chain_id = 56),
  verifier bytea NOT NULL CHECK (octet_length(verifier) = 20),
  digest bytea NOT NULL CHECK (octet_length(digest) = 32),
  consumer bytea NOT NULL CHECK (octet_length(consumer) = 20),
  creator bytea NOT NULL CHECK (octet_length(creator) = 20),
  launch_request_hash bytea NOT NULL CHECK (octet_length(launch_request_hash) = 32),
  quote_token bytea NOT NULL CHECK (octet_length(quote_token) = 20),
  reference_token bytea NOT NULL CHECK (octet_length(reference_token) = 20),
  reference_pool bytea NOT NULL CHECK (octet_length(reference_pool) = 20),
  price_usd_wad numeric(78,0) NOT NULL CHECK (price_usd_wad > 0),
  liquidity_usd_wad numeric(78,0) NOT NULL CHECK (liquidity_usd_wad >= 0),
  observation_timestamp timestamptz NOT NULL,
  attestation_deadline timestamptz NOT NULL,
  nonce bytea NOT NULL CHECK (octet_length(nonce) = 32),
  block_hash bytea NOT NULL CHECK (octet_length(block_hash) = 32),
  block_number bigint NOT NULL CHECK (block_number >= 0),
  tx_hash bytea NOT NULL CHECK (octet_length(tx_hash) = 32),
  tx_index integer NOT NULL CHECK (tx_index >= 0),
  log_index integer NOT NULL CHECK (log_index >= 0),
  canonical boolean NOT NULL DEFAULT true,
  orphaned_at timestamptz,
  orphan_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (chain_id, block_hash, tx_hash, log_index),
  FOREIGN KEY (chain_id, block_hash, tx_hash, log_index)
    REFERENCES raw_logs(chain_id, block_hash, tx_hash, log_index),
  CONSTRAINT quote_price_attestation_orphan_state CHECK (
    (canonical AND orphaned_at IS NULL)
    OR (NOT canonical AND orphaned_at IS NOT NULL)
  )
);
CREATE UNIQUE INDEX IF NOT EXISTS quote_price_attestation_one_canonical_digest
  ON quote_price_attestation_facts(chain_id, digest) WHERE canonical;
CREATE INDEX IF NOT EXISTS quote_price_attestation_consumer_order
  ON quote_price_attestation_facts(chain_id, consumer, block_number, tx_index, log_index)
  WHERE canonical;

CREATE TABLE IF NOT EXISTS direct_market_launch_facts (
  chain_id bigint NOT NULL CHECK (chain_id = 56),
  engine bytea NOT NULL CHECK (octet_length(engine) = 20),
  launch_id numeric(78,0) NOT NULL,
  creator bytea NOT NULL CHECK (octet_length(creator) = 20),
  token bytea NOT NULL CHECK (octet_length(token) = 20),
  quote_token bytea NOT NULL CHECK (octet_length(quote_token) = 20),
  pool bytea NOT NULL CHECK (octet_length(pool) = 20),
  locker bytea NOT NULL CHECK (octet_length(locker) = 20),
  position_token_id numeric(78,0) NOT NULL CHECK (position_token_id > 0),
  deposited_supply numeric(78,0) NOT NULL CHECK (deposited_supply > 0),
  target_fdv_usd_wad numeric(78,0) NOT NULL CHECK (target_fdv_usd_wad > 0),
  quote_price_usd_wad numeric(78,0) NOT NULL CHECK (quote_price_usd_wad > 0),
  sqrt_price_x96 numeric(78,0) NOT NULL CHECK (sqrt_price_x96 > 0),
  tick_lower integer NOT NULL,
  tick_upper integer NOT NULL,
  fee_tier integer NOT NULL CHECK (fee_tier BETWEEN 1 AND 1000000),
  attestation_digest bytea NOT NULL CHECK (octet_length(attestation_digest) = 32),
  block_hash bytea NOT NULL CHECK (octet_length(block_hash) = 32),
  block_number bigint NOT NULL CHECK (block_number >= 0),
  tx_hash bytea NOT NULL CHECK (octet_length(tx_hash) = 32),
  tx_index integer NOT NULL CHECK (tx_index >= 0),
  log_index integer NOT NULL CHECK (log_index >= 0),
  canonical boolean NOT NULL DEFAULT true,
  orphaned_at timestamptz,
  orphan_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (chain_id, block_hash, tx_hash, log_index),
  FOREIGN KEY (chain_id, block_hash, tx_hash, log_index)
    REFERENCES raw_logs(chain_id, block_hash, tx_hash, log_index),
  CONSTRAINT direct_market_launch_orphan_state CHECK (
    (canonical AND orphaned_at IS NULL)
    OR (NOT canonical AND orphaned_at IS NOT NULL)
  )
);
CREATE UNIQUE INDEX IF NOT EXISTS direct_market_launch_one_canonical_launch
  ON direct_market_launch_facts(chain_id, engine, launch_id) WHERE canonical;
CREATE INDEX IF NOT EXISTS direct_market_launch_attestation
  ON direct_market_launch_facts(chain_id, attestation_digest) WHERE canonical;

CREATE OR REPLACE FUNCTION quote_wad_to_usd(value_wad numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN value_wad IS NULL THEN NULL
    ELSE value_wad / 1000000000000000000::numeric
  END;
$$;

CREATE OR REPLACE FUNCTION quote_raw_usd_value(
  quote_raw numeric,
  quote_price_usd_wad numeric,
  quote_decimals integer
) RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN quote_raw IS NULL OR quote_price_usd_wad IS NULL OR quote_decimals IS NULL
      OR quote_decimals < 0 OR quote_decimals > 36
      THEN NULL
    ELSE (quote_raw * quote_price_usd_wad)
      / (power(10::numeric, quote_decimals) * 1000000000000000000::numeric)
  END;
$$;

CREATE OR REPLACE FUNCTION quote_market_cap_usd(
  supply_raw numeric,
  price_numerator_raw numeric,
  price_denominator_raw numeric,
  quote_price_usd_wad numeric,
  quote_decimals integer
) RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN supply_raw IS NULL OR price_numerator_raw IS NULL OR price_denominator_raw IS NULL
      OR quote_price_usd_wad IS NULL OR quote_decimals IS NULL
      OR supply_raw <= 0 OR price_numerator_raw <= 0 OR price_denominator_raw <= 0
      OR quote_decimals < 0 OR quote_decimals > 36
      THEN NULL
    ELSE (supply_raw * price_numerator_raw * quote_price_usd_wad)
      / (price_denominator_raw * power(10::numeric, quote_decimals) * 1000000000000000000::numeric)
  END;
$$;

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

CREATE OR REPLACE FUNCTION apply_quote_attestation_valuation(
  target_chain_id bigint,
  target_digest bytea
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  direct_row record;
BEGIN
  FOR direct_row IN
    SELECT engine, launch_id
    FROM direct_market_launch_facts
    WHERE chain_id = target_chain_id
      AND attestation_digest = target_digest
      AND canonical
  LOOP
    PERFORM apply_direct_market_valuation(target_chain_id, direct_row.engine, direct_row.launch_id);
  END LOOP;
END;
$$;

COMMIT;
