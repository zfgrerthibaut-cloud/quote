BEGIN;

ALTER TABLE market_trade_events
  ADD COLUMN IF NOT EXISTS token_amount_signed_raw numeric(78,0),
  ADD COLUMN IF NOT EXISTS quote_amount_signed_raw numeric(78,0);

COMMENT ON COLUMN market_trade_events.token_amount_signed_raw IS
  'Signed Pancake V3 pool delta reoriented to the launch token. Buys are negative, sells are positive.';
COMMENT ON COLUMN market_trade_events.quote_amount_signed_raw IS
  'Signed Pancake V3 pool delta reoriented to the quote token. Buys are positive, sells are negative.';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'market_trade_direct_signed_amounts'
  ) THEN
    ALTER TABLE market_trade_events
      ADD CONSTRAINT market_trade_direct_signed_amounts CHECK (
        (token_amount_signed_raw IS NULL AND quote_amount_signed_raw IS NULL)
        OR (
          token_amount_signed_raw <> 0
          AND quote_amount_signed_raw <> 0
          AND abs(token_amount_signed_raw) = token_amount_raw
          AND abs(quote_amount_signed_raw) = quote_amount_raw
          AND (
            (trade_type = 'buy' AND token_amount_signed_raw < 0 AND quote_amount_signed_raw > 0)
            OR (trade_type = 'sell' AND token_amount_signed_raw > 0 AND quote_amount_signed_raw < 0)
          )
        )
      );
  END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS markets_direct_pool_lookup
  ON markets(chain_id, market) WHERE engine_kind = 1;

CREATE TABLE IF NOT EXISTS indexer_pancake_v3_pool_cursors (
  chain_id bigint NOT NULL CHECK (chain_id = 56),
  market bytea NOT NULL CHECK (octet_length(market) = 20),
  launchpad bytea NOT NULL CHECK (octet_length(launchpad) = 20),
  launch_id numeric(78,0) NOT NULL,
  start_block bigint NOT NULL CHECK (start_block > 0),
  indexed_through bigint NOT NULL CHECK (indexed_through >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (chain_id, market),
  FOREIGN KEY (chain_id, launchpad, launch_id)
    REFERENCES markets(chain_id, launchpad, launch_id) ON DELETE CASCADE,
  CHECK (indexed_through >= start_block - 1)
);

COMMENT ON TABLE indexer_pancake_v3_pool_cursors IS
  'Dynamic Pancake V3 Swap scan cursors derived from QUOTE DIRECT markets.market.';

INSERT INTO indexer_pancake_v3_pool_cursors(
  chain_id, market, launchpad, launch_id, start_block, indexed_through
)
SELECT chain_id, market, launchpad, launch_id, launch_block, launch_block - 1
FROM markets
WHERE engine_kind = 1
ON CONFLICT (chain_id, market) DO NOTHING;

CREATE OR REPLACE FUNCTION normalize_quote_outbox_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  signed_token text;
  signed_quote text;
BEGIN
  IF NEW.topic = 'market.trade.upsert' AND NEW.payload ? 'tradeEventId' THEN
    SELECT token_amount_signed_raw::text, quote_amount_signed_raw::text
      INTO signed_token, signed_quote
    FROM market_trade_events
    WHERE trade_event_id = (NEW.payload->>'tradeEventId')::bigint;

    IF FOUND THEN
      NEW.payload := NEW.payload || jsonb_build_object(
        'tokenAmountSignedRaw', signed_token,
        'quoteAmountSignedRaw', signed_quote
      );
    END IF;
  END IF;

  IF NEW.dedupe_key IS NULL THEN
    IF NEW.topic = 'market.trade.upsert' AND NEW.payload ? 'tradeEventId' THEN
      NEW.dedupe_key := concat('market.trade.upsert:', NEW.payload->>'tradeEventId');
    ELSIF NEW.topic = 'market.trade.reorg' AND NEW.payload ? 'tradeEventId' THEN
      NEW.dedupe_key := concat(
        'market.trade.reorg:',
        NEW.payload->>'tradeEventId',
        ':',
        NEW.payload->>'canonical'
      );
    ELSIF NEW.topic = 'market.trades.rebuilt' THEN
      NEW.dedupe_key := concat(
        'market.trades.rebuilt:',
        NEW.payload->>'chainId',
        ':',
        NEW.payload->>'launchpad',
        ':',
        NEW.payload->>'launchId',
        ':',
        NEW.payload->>'asOf'
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS outbox_normalize_quote_insert ON outbox;
CREATE TRIGGER outbox_normalize_quote_insert
BEFORE INSERT ON outbox
FOR EACH ROW EXECUTE FUNCTION normalize_quote_outbox_insert();

COMMIT;
