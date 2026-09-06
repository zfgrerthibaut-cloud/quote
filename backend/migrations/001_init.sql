BEGIN;

CREATE TABLE chain_cursors (
  chain_id bigint PRIMARY KEY,
  canonical_number bigint NOT NULL CHECK (canonical_number >= 0),
  canonical_hash bytea NOT NULL CHECK (octet_length(canonical_hash) = 32),
  observed_number bigint NOT NULL CHECK (observed_number >= canonical_number),
  finalized_number bigint NOT NULL CHECK (finalized_number <= canonical_number),
  generation bigint NOT NULL DEFAULT 0,
  status text NOT NULL CHECK (status IN ('syncing', 'live', 'stale', 'halted')),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE chain_blocks (
  chain_id bigint NOT NULL,
  number bigint NOT NULL CHECK (number >= 0),
  hash bytea NOT NULL CHECK (octet_length(hash) = 32),
  parent_hash bytea NOT NULL CHECK (octet_length(parent_hash) = 32),
  block_time timestamptz NOT NULL,
  canonical boolean NOT NULL DEFAULT true,
  observed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (chain_id, hash)
);
CREATE UNIQUE INDEX chain_blocks_one_canonical_height
  ON chain_blocks(chain_id, number) WHERE canonical;

CREATE TABLE raw_logs (
  chain_id bigint NOT NULL,
  block_hash bytea NOT NULL CHECK (octet_length(block_hash) = 32),
  block_number bigint NOT NULL,
  tx_hash bytea NOT NULL CHECK (octet_length(tx_hash) = 32),
  tx_index integer NOT NULL CHECK (tx_index >= 0),
  log_index integer NOT NULL CHECK (log_index >= 0),
  address bytea NOT NULL CHECK (octet_length(address) = 20),
  topics jsonb NOT NULL,
  data bytea NOT NULL,
  decoded jsonb,
  canonical boolean NOT NULL DEFAULT true,
  PRIMARY KEY (chain_id, block_hash, tx_hash, log_index),
  FOREIGN KEY (chain_id, block_hash) REFERENCES chain_blocks(chain_id, hash)
);
CREATE INDEX raw_logs_canonical_order ON raw_logs(chain_id, block_number, tx_index, log_index) WHERE canonical;

CREATE TABLE markets (
  chain_id bigint NOT NULL,
  launchpad bytea NOT NULL CHECK (octet_length(launchpad) = 20),
  launch_id numeric(78,0) NOT NULL,
  engine_kind smallint NOT NULL CHECK (engine_kind IN (1, 2)),
  engine_version bytea NOT NULL CHECK (octet_length(engine_version) = 32),
  creator bytea NOT NULL CHECK (octet_length(creator) = 20),
  token bytea NOT NULL CHECK (octet_length(token) = 20),
  quote_token bytea NOT NULL CHECK (octet_length(quote_token) = 20),
  market bytea NOT NULL CHECK (octet_length(market) = 20),
  hook bytea NOT NULL CHECK (octet_length(hook) = 20),
  vault bytea NOT NULL CHECK (octet_length(vault) = 20),
  locker bytea NOT NULL CHECK (octet_length(locker) = 20),
  pool_id bytea NOT NULL CHECK (octet_length(pool_id) = 32),
  engine_record_id bytea NOT NULL CHECK (octet_length(engine_record_id) = 32),
  supply numeric(78,0) NOT NULL,
  creator_fee_bps integer NOT NULL CHECK (creator_fee_bps BETWEEN 0 AND 100),
  reward_fee_bps integer NOT NULL CHECK (reward_fee_bps BETWEEN 0 AND 300),
  creator_lp_share_bps integer NOT NULL CHECK (creator_lp_share_bps BETWEEN 0 AND 10000),
  market_cap_usd numeric,
  volume_24h_usd numeric,
  liquidity_usd numeric,
  launch_block bigint NOT NULL,
  launch_tx_hash bytea NOT NULL CHECK (octet_length(launch_tx_hash) = 32),
  launch_log_index integer NOT NULL,
  launched_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (chain_id, launchpad, launch_id),
  UNIQUE (chain_id, token),
  UNIQUE (chain_id, engine_record_id)
);
CREATE INDEX markets_by_cap ON markets(chain_id, market_cap_usd DESC NULLS LAST, launch_id DESC);
CREATE INDEX markets_by_newest ON markets(chain_id, launch_block DESC, launch_log_index DESC);
CREATE INDEX markets_by_volume ON markets(chain_id, volume_24h_usd DESC NULLS LAST, launch_id DESC);

CREATE TABLE outbox (
  id bigserial PRIMARY KEY,
  topic text NOT NULL,
  aggregate_id text NOT NULL,
  payload jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  published_at timestamptz
);
CREATE INDEX outbox_unpublished ON outbox(id) WHERE published_at IS NULL;

CREATE TABLE media_resolution_cache (
  chain_id bigint NOT NULL,
  token_address bytea NOT NULL CHECK (octet_length(token_address) = 20),
  status text NOT NULL CHECK (status IN ('pending', 'fetching', 'ready', 'negative', 'rejected')),
  source text CHECK (source IN ('creator', 'dexscreener', 'gmgn')),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  next_retry_at timestamptz,
  source_etag text,
  content_hash bytea CHECK (content_hash IS NULL OR octet_length(content_hash) = 32),
  object_key text,
  mime text CHECK (mime IS NULL OR mime IN ('image/png', 'image/webp')),
  width integer CHECK (width IS NULL OR width BETWEEN 1 AND 4096),
  height integer CHECK (height IS NULL OR height BETWEEN 1 AND 4096),
  expires_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (chain_id, token_address),
  CHECK ((status = 'ready') = (content_hash IS NOT NULL AND object_key IS NOT NULL))
);
CREATE INDEX media_retry_queue ON media_resolution_cache(next_retry_at)
  WHERE status IN ('pending', 'fetching');

COMMIT;
