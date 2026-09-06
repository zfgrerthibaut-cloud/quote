BEGIN;

ALTER TABLE outbox ADD COLUMN dedupe_key text;
CREATE UNIQUE INDEX outbox_dedupe_key_unique ON outbox(dedupe_key);

COMMENT ON COLUMN outbox.dedupe_key IS
  'Stable producer idempotency key. Legacy trigger emissions may leave it NULL.';

CREATE TABLE indexer_contract_registry (
  chain_id bigint NOT NULL CHECK (chain_id = 56),
  address bytea NOT NULL CHECK (octet_length(address) = 20),
  start_block bigint NOT NULL CHECK (start_block > 0),
  abi_version_hash bytea NOT NULL CHECK (octet_length(abi_version_hash) = 32),
  installed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (chain_id, address, start_block)
);

COMMENT ON TABLE indexer_contract_registry IS
  'Fail-closed snapshot of explicitly configured QUOTE contracts and canonical ABI SHA-256 hashes.';

COMMIT;
