BEGIN;

ALTER TABLE indexer_contract_registry
  ADD COLUMN IF NOT EXISTS kind text DEFAULT 'plain',
  ADD COLUMN IF NOT EXISTS proxy_runtime_code_hash bytea
    CHECK (proxy_runtime_code_hash IS NULL OR octet_length(proxy_runtime_code_hash) = 32),
  ADD COLUMN IF NOT EXISTS implementation_address bytea
    CHECK (implementation_address IS NULL OR octet_length(implementation_address) = 20),
  ADD COLUMN IF NOT EXISTS implementation_runtime_code_hash bytea
    CHECK (implementation_runtime_code_hash IS NULL OR octet_length(implementation_runtime_code_hash) = 32);

UPDATE indexer_contract_registry
SET kind = 'plain'
WHERE kind IS NULL AND runtime_code_hash IS NOT NULL;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM indexer_contract_registry
    WHERE runtime_code_hash IS NULL OR kind IS NULL
  ) THEN
    RAISE EXCEPTION 'indexer_contract_registry_legacy_runtime_pin_null';
  END IF;
END
$$;

ALTER TABLE indexer_contract_registry
  ALTER COLUMN kind SET NOT NULL,
  ALTER COLUMN runtime_code_hash SET NOT NULL;

ALTER TABLE indexer_contract_registry
  ADD CONSTRAINT indexer_contract_registry_kind_check
    CHECK (kind IN ('plain', 'erc1967-uups')),
  ADD CONSTRAINT indexer_contract_registry_runtime_pin_shape
    CHECK (
      (
        kind = 'plain'
        AND proxy_runtime_code_hash IS NULL
        AND implementation_address IS NULL
        AND implementation_runtime_code_hash IS NULL
      )
      OR (
        kind = 'erc1967-uups'
        AND proxy_runtime_code_hash IS NOT NULL
        AND runtime_code_hash = proxy_runtime_code_hash
        AND implementation_address IS NOT NULL
        AND implementation_runtime_code_hash IS NOT NULL
      )
    );

COMMENT ON COLUMN indexer_contract_registry.kind IS
  'Registry runtime pin kind. plain pins the contract code at address; erc1967-uups pins proxy code, implementation slot and implementation code.';
COMMENT ON COLUMN indexer_contract_registry.proxy_runtime_code_hash IS
  'Keccak-256 of the ERC-1967 proxy runtime bytecode. For UUPS entries this equals runtime_code_hash.';
COMMENT ON COLUMN indexer_contract_registry.implementation_address IS
  'Expected address stored in the ERC-1967 implementation slot at validation time.';
COMMENT ON COLUMN indexer_contract_registry.implementation_runtime_code_hash IS
  'Keccak-256 of the expected implementation runtime bytecode.';

COMMIT;
