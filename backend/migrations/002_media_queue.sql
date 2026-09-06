BEGIN;

ALTER TABLE media_resolution_cache
  ADD COLUMN lease_owner text,
  ADD COLUMN lease_expires_at timestamptz,
  ADD COLUMN lease_generation bigint NOT NULL DEFAULT 0,
  ADD COLUMN max_attempts integer NOT NULL DEFAULT 6 CHECK (max_attempts BETWEEN 1 AND 12),
  ADD COLUMN provider_ref text,
  ADD COLUMN provider_payload_hash bytea CHECK (provider_payload_hash IS NULL OR octet_length(provider_payload_hash) = 32),
  ADD COLUMN byte_size integer CHECK (byte_size IS NULL OR byte_size BETWEEN 1 AND 1500000),
  ADD COLUMN last_error_code text,
  ADD COLUMN last_requested_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN last_resolved_at timestamptz,
  ADD CONSTRAINT media_lease_is_complete CHECK (
    (lease_owner IS NULL AND lease_expires_at IS NULL)
    OR (lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL)
  ),
  ADD CONSTRAINT media_attempts_are_bounded CHECK (attempt_count <= max_attempts),
  ADD CONSTRAINT media_ready_is_complete CHECK (
    status <> 'ready'
    OR (
      source IS NOT NULL
      AND provider_ref IS NOT NULL
      AND content_hash IS NOT NULL
      AND object_key IS NOT NULL
      AND mime IS NOT NULL
      AND width IS NOT NULL
      AND height IS NOT NULL
      AND byte_size IS NOT NULL
      AND last_resolved_at IS NOT NULL
    )
  );

ALTER TABLE media_resolution_cache
  DROP CONSTRAINT media_resolution_cache_source_check,
  ADD CONSTRAINT media_resolution_cache_source_check
    CHECK (source IN ('creator', 'dexscreener', 'gmgn', 'codex'));

CREATE TABLE media_resolution_attempts (
  id bigserial PRIMARY KEY,
  chain_id bigint NOT NULL,
  token_address bytea NOT NULL CHECK (octet_length(token_address) = 20),
  lease_generation bigint NOT NULL,
  provider text NOT NULL CHECK (provider IN ('creator', 'dexscreener', 'gmgn', 'codex')),
  outcome text NOT NULL CHECK (outcome IN ('hit', 'miss', 'retryable_error', 'rejected')),
  http_status integer CHECK (http_status IS NULL OR http_status BETWEEN 100 AND 599),
  error_code text,
  provider_payload_hash bytea CHECK (provider_payload_hash IS NULL OR octet_length(provider_payload_hash) = 32),
  started_at timestamptz NOT NULL,
  completed_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (chain_id, token_address)
    REFERENCES media_resolution_cache(chain_id, token_address)
);
CREATE INDEX media_attempts_by_token
  ON media_resolution_attempts(chain_id, token_address, id DESC);

DROP INDEX media_retry_queue;
CREATE INDEX media_retry_queue
  ON media_resolution_cache(next_retry_at, expires_at, updated_at)
  WHERE status IN ('pending', 'fetching', 'ready', 'negative');

CREATE OR REPLACE FUNCTION request_token_media(
  requested_chain_id bigint,
  requested_token_address bytea
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF octet_length(requested_token_address) <> 20 THEN
    RAISE EXCEPTION 'invalid_token_address';
  END IF;

  INSERT INTO media_resolution_cache (
    chain_id,
    token_address,
    status,
    next_retry_at,
    expires_at,
    last_requested_at
  ) VALUES (
    requested_chain_id,
    requested_token_address,
    'pending',
    now(),
    now(),
    now()
  )
  ON CONFLICT (chain_id, token_address) DO UPDATE
  SET
    last_requested_at = now(),
    status = CASE
      WHEN media_resolution_cache.status = 'negative'
        AND media_resolution_cache.expires_at <= now()
        THEN 'pending'
      ELSE media_resolution_cache.status
    END,
    next_retry_at = CASE
      WHEN media_resolution_cache.status = 'negative'
        AND media_resolution_cache.expires_at <= now()
        THEN now()
      ELSE media_resolution_cache.next_retry_at
    END,
    attempt_count = CASE
      WHEN media_resolution_cache.status = 'negative'
        AND media_resolution_cache.expires_at <= now()
        THEN 0
      ELSE media_resolution_cache.attempt_count
    END;
END;
$$;

CREATE OR REPLACE FUNCTION enqueue_market_media()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM request_token_media(NEW.chain_id, NEW.token);
  PERFORM request_token_media(NEW.chain_id, NEW.quote_token);
  RETURN NEW;
END;
$$;

CREATE TRIGGER markets_enqueue_media
AFTER INSERT ON markets
FOR EACH ROW EXECUTE FUNCTION enqueue_market_media();

-- A worker calls this inside a transaction. SKIP LOCKED ensures that replicas
-- never download the same token concurrently. Ready rows keep their object
-- while a refresh runs, so the API can serve stale media during provider errors.
CREATE OR REPLACE FUNCTION claim_media_resolution(
  worker_id text,
  lease_seconds integer DEFAULT 30
) RETURNS TABLE (
  chain_id bigint,
  token_address bytea,
  previous_status text,
  attempt_count integer,
  lease_generation bigint,
  stale_object_key text
)
LANGUAGE sql
AS $$
  WITH candidate AS (
    SELECT cache.chain_id, cache.token_address
    FROM media_resolution_cache AS cache
    WHERE (
      (
        cache.status IN ('pending', 'fetching')
        AND cache.attempt_count < cache.max_attempts
        AND COALESCE(cache.next_retry_at, '-infinity'::timestamptz) <= now()
      )
      OR (
        cache.status IN ('ready', 'negative')
        AND cache.expires_at <= now()
        AND COALESCE(cache.next_retry_at, '-infinity'::timestamptz) <= now()
      )
    )
    AND (cache.lease_expires_at IS NULL OR cache.lease_expires_at <= now())
    ORDER BY cache.last_requested_at DESC, cache.updated_at ASC
    FOR UPDATE SKIP LOCKED
    LIMIT 1
  ), claimed AS (
    UPDATE media_resolution_cache AS cache
    SET
      status = CASE WHEN cache.status IN ('pending', 'negative') THEN 'fetching' ELSE cache.status END,
      lease_owner = worker_id,
      lease_expires_at = now() + make_interval(secs => GREATEST(5, LEAST(lease_seconds, 300))),
      lease_generation = cache.lease_generation + 1,
      attempt_count = CASE
        WHEN cache.status IN ('ready', 'negative') THEN 1
        ELSE cache.attempt_count + 1
      END,
      updated_at = now()
    FROM candidate
    WHERE cache.chain_id = candidate.chain_id
      AND cache.token_address = candidate.token_address
    RETURNING
      cache.chain_id,
      cache.token_address,
      CASE WHEN cache.object_key IS NULL THEN 'pending' ELSE 'ready' END,
      cache.attempt_count,
      cache.lease_generation,
      cache.object_key
  )
  SELECT * FROM claimed;
$$;

CREATE OR REPLACE FUNCTION complete_media_resolution(
  worker_id text,
  resolved_chain_id bigint,
  resolved_token_address bytea,
  resolved_lease_generation bigint,
  resolved_source text,
  resolved_provider_ref text,
  resolved_provider_payload_hash bytea,
  resolved_content_hash bytea,
  resolved_mime text,
  resolved_byte_size integer,
  resolved_width integer,
  resolved_height integer,
  positive_ttl_seconds integer DEFAULT 86400
) RETURNS boolean
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE media_resolution_cache
  SET
    status = 'ready',
    source = resolved_source,
    provider_ref = left(resolved_provider_ref, 512),
    provider_payload_hash = resolved_provider_payload_hash,
    content_hash = resolved_content_hash,
    object_key = 'media/sha256/' || encode(resolved_content_hash, 'hex')
      || CASE WHEN resolved_mime = 'image/png' THEN '.png' ELSE '.webp' END,
    mime = resolved_mime,
    byte_size = resolved_byte_size,
    width = resolved_width,
    height = resolved_height,
    expires_at = now() + make_interval(secs => GREATEST(300, LEAST(positive_ttl_seconds, 604800))),
    next_retry_at = NULL,
    last_error_code = NULL,
    last_resolved_at = now(),
    lease_owner = NULL,
    lease_expires_at = NULL,
    updated_at = now()
  WHERE chain_id = resolved_chain_id
    AND token_address = resolved_token_address
    AND lease_owner = worker_id
    AND lease_generation = resolved_lease_generation
    AND lease_expires_at > now();

  RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION fail_media_resolution(
  worker_id text,
  failed_chain_id bigint,
  failed_token_address bytea,
  failed_lease_generation bigint,
  error_code text,
  retry_seconds integer DEFAULT 300
) RETURNS boolean
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE media_resolution_cache
  SET
    -- Preserve a previously validated object during a refresh failure.
    status = CASE
      WHEN object_key IS NOT NULL THEN 'ready'
      WHEN attempt_count >= max_attempts THEN 'negative'
      ELSE 'pending'
    END,
    expires_at = CASE
      WHEN object_key IS NULL AND attempt_count >= max_attempts
        THEN now() + make_interval(secs => GREATEST(60, LEAST(retry_seconds, 86400)))
      ELSE expires_at
    END,
    next_retry_at = now() + make_interval(secs => GREATEST(60, LEAST(retry_seconds, 86400))),
    last_error_code = left(error_code, 64),
    lease_owner = NULL,
    lease_expires_at = NULL,
    updated_at = now()
  WHERE chain_id = failed_chain_id
    AND token_address = failed_token_address
    AND lease_owner = worker_id
    AND lease_generation = failed_lease_generation
    AND lease_expires_at > now();

  RETURN FOUND;
END;
$$;

COMMIT;
