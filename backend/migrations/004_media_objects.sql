BEGIN;

-- Sanitized outputs only. Provider uploads never enter this table. Production
-- can replace this table with S3/R2 while keeping the same content-addressed key.
CREATE TABLE media_objects (
  content_hash bytea PRIMARY KEY CHECK (octet_length(content_hash) = 32),
  mime text NOT NULL CHECK (mime IN ('image/png', 'image/webp')),
  object_key text GENERATED ALWAYS AS (
    'media/sha256/' || encode(content_hash, 'hex')
      || CASE WHEN mime = 'image/png' THEN '.png' ELSE '.webp' END
  ) STORED UNIQUE,
  bytes bytea NOT NULL CHECK (octet_length(bytes) BETWEEN 1 AND 1500000),
  byte_length integer NOT NULL CHECK (byte_length = octet_length(bytes)),
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE media_resolution_cache
  ADD CONSTRAINT media_object_key_is_content_addressed CHECK (
    object_key IS NULL
    OR object_key = 'media/sha256/' || encode(content_hash, 'hex')
      || CASE WHEN mime = 'image/png' THEN '.png' ELSE '.webp' END
  );

COMMIT;
