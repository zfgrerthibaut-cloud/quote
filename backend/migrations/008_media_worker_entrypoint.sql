BEGIN;

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
      WHEN media_resolution_cache.status IN ('negative', 'rejected')
        AND media_resolution_cache.expires_at <= now()
        THEN 'pending'
      ELSE media_resolution_cache.status
    END,
    next_retry_at = CASE
      WHEN media_resolution_cache.status IN ('negative', 'rejected')
        AND media_resolution_cache.expires_at <= now()
        THEN now()
      ELSE media_resolution_cache.next_retry_at
    END,
    attempt_count = CASE
      WHEN media_resolution_cache.status IN ('negative', 'rejected')
        AND media_resolution_cache.expires_at <= now()
        THEN 0
      ELSE media_resolution_cache.attempt_count
    END;
END;
$$;

DROP INDEX IF EXISTS media_retry_queue;
CREATE INDEX media_retry_queue
  ON media_resolution_cache(next_retry_at, expires_at, updated_at)
  WHERE status IN ('pending', 'fetching', 'ready', 'negative', 'rejected');

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
        cache.status IN ('ready', 'negative', 'rejected')
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
      status = CASE WHEN cache.status IN ('pending', 'negative', 'rejected') THEN 'fetching' ELSE cache.status END,
      lease_owner = worker_id,
      lease_expires_at = now() + make_interval(secs => GREATEST(5, LEAST(lease_seconds, 300))),
      lease_generation = cache.lease_generation + 1,
      attempt_count = CASE
        WHEN cache.status IN ('ready', 'negative', 'rejected') THEN 1
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

-- Public image reads may enqueue work only for tokens already indexed as a
-- QUOTE market token or quote token. This keeps arbitrary public addresses from
-- filling the media queue, and it throttles repeated cache misses per token.
CREATE OR REPLACE FUNCTION request_known_token_media(
  requested_chain_id bigint,
  requested_token_address bytea,
  min_request_seconds integer DEFAULT 30,
  requested_at timestamptz DEFAULT now()
) RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  bounded_min_request_seconds integer;
BEGIN
  IF octet_length(requested_token_address) <> 20 THEN
    RAISE EXCEPTION 'invalid_token_address';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM markets
    WHERE chain_id = requested_chain_id
      AND (token = requested_token_address OR quote_token = requested_token_address)
    LIMIT 1
  ) THEN
    RETURN 'unknown';
  END IF;

  bounded_min_request_seconds := GREATEST(1, LEAST(min_request_seconds, 300));
  IF EXISTS (
    SELECT 1
    FROM media_resolution_cache
    WHERE chain_id = requested_chain_id
      AND token_address = requested_token_address
      AND last_requested_at > requested_at - make_interval(secs => bounded_min_request_seconds)
      AND NOT (
        status IN ('negative', 'rejected')
        AND expires_at <= requested_at
      )
    LIMIT 1
  ) THEN
    RETURN 'rate_limited';
  END IF;

  PERFORM request_token_media(requested_chain_id, requested_token_address);
  RETURN 'queued';
END;
$$;

CREATE OR REPLACE FUNCTION complete_media_miss(
  worker_id text,
  missed_chain_id bigint,
  missed_token_address bytea,
  missed_lease_generation bigint,
  missed_status text,
  missed_source text,
  error_code text,
  negative_ttl_seconds integer DEFAULT 300
) RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  bounded_negative_ttl_seconds integer;
BEGIN
  IF missed_status NOT IN ('negative', 'rejected') THEN
    RAISE EXCEPTION 'invalid_media_miss_status';
  END IF;

  IF missed_source IS NOT NULL AND missed_source NOT IN ('creator', 'dexscreener', 'gmgn', 'codex') THEN
    RAISE EXCEPTION 'invalid_media_miss_source';
  END IF;

  bounded_negative_ttl_seconds := GREATEST(60, LEAST(negative_ttl_seconds, 86400));

  UPDATE media_resolution_cache
  SET
    -- Keep a previously sanitized object live while later refreshes miss.
    status = CASE WHEN object_key IS NOT NULL THEN 'ready' ELSE missed_status END,
    source = CASE WHEN object_key IS NOT NULL THEN source ELSE missed_source END,
    provider_ref = CASE WHEN object_key IS NOT NULL THEN provider_ref ELSE NULL END,
    provider_payload_hash = CASE WHEN object_key IS NOT NULL THEN provider_payload_hash ELSE NULL END,
    content_hash = CASE WHEN object_key IS NOT NULL THEN content_hash ELSE NULL END,
    object_key = CASE WHEN object_key IS NOT NULL THEN object_key ELSE NULL END,
    mime = CASE WHEN object_key IS NOT NULL THEN mime ELSE NULL END,
    byte_size = CASE WHEN object_key IS NOT NULL THEN byte_size ELSE NULL END,
    width = CASE WHEN object_key IS NOT NULL THEN width ELSE NULL END,
    height = CASE WHEN object_key IS NOT NULL THEN height ELSE NULL END,
    expires_at = now() + make_interval(secs => bounded_negative_ttl_seconds),
    next_retry_at = now() + make_interval(secs => bounded_negative_ttl_seconds),
    last_error_code = left(error_code, 64),
    lease_owner = NULL,
    lease_expires_at = NULL,
    updated_at = now()
  WHERE chain_id = missed_chain_id
    AND token_address = missed_token_address
    AND lease_owner = worker_id
    AND lease_generation = missed_lease_generation
    AND lease_expires_at > now();

  RETURN FOUND;
END;
$$;

COMMIT;
