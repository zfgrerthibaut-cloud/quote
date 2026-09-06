BEGIN;

ALTER TABLE indexer_contract_registry
  ADD COLUMN IF NOT EXISTS runtime_code_hash bytea
    CHECK (runtime_code_hash IS NULL OR octet_length(runtime_code_hash) = 32);

COMMENT ON COLUMN indexer_contract_registry.runtime_code_hash IS
  'Keccak-256 of the configured contract runtime bytecode, verified against BSC before indexing.';

COMMIT;
