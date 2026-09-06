BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE token_metadata (
  chain_id bigint NOT NULL,
  token_address bytea NOT NULL CHECK (octet_length(token_address) = 20),
  name text,
  symbol text,
  decimals smallint CHECK (decimals IS NULL OR decimals BETWEEN 0 AND 36),
  source_block_hash bytea CHECK (source_block_hash IS NULL OR octet_length(source_block_hash) = 32),
  source_block_number bigint CHECK (source_block_number IS NULL OR source_block_number >= 0),
  verified_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (chain_id, token_address),
  CHECK (name IS NULL OR char_length(name) BETWEEN 1 AND 128),
  CHECK (symbol IS NULL OR char_length(symbol) BETWEEN 1 AND 32)
);
CREATE INDEX token_metadata_name_search ON token_metadata USING gin (lower(name) gin_trgm_ops);
CREATE INDEX token_metadata_symbol_search ON token_metadata USING gin (lower(symbol) gin_trgm_ops);

CREATE OR REPLACE FUNCTION notify_quote_outbox()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM pg_notify('quote_outbox', NEW.id::text);
  RETURN NEW;
END;
$$;

CREATE TRIGGER outbox_notify_realtime
AFTER INSERT ON outbox
FOR EACH ROW EXECUTE FUNCTION notify_quote_outbox();

COMMIT;
