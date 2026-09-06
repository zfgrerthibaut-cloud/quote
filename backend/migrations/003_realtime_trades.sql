BEGIN;

CREATE TABLE market_trade_events (
  trade_event_id bigserial PRIMARY KEY,
  chain_id bigint NOT NULL,
  launchpad bytea NOT NULL CHECK (octet_length(launchpad) = 20),
  launch_id numeric(78,0) NOT NULL,
  phase text NOT NULL CHECK (phase IN ('curve', 'pool')),
  trade_type text NOT NULL CHECK (trade_type IN ('buy', 'sell', 'swap')),
  venue bytea NOT NULL CHECK (octet_length(venue) = 20),
  trader bytea CHECK (trader IS NULL OR octet_length(trader) = 20),
  recipient bytea CHECK (recipient IS NULL OR octet_length(recipient) = 20),
  token_in bytea NOT NULL CHECK (octet_length(token_in) = 20),
  token_out bytea NOT NULL CHECK (octet_length(token_out) = 20),
  amount_in_raw numeric(78,0) NOT NULL CHECK (amount_in_raw > 0),
  amount_out_raw numeric(78,0) NOT NULL CHECK (amount_out_raw > 0),
  token_amount_raw numeric(78,0) NOT NULL CHECK (token_amount_raw > 0),
  quote_amount_raw numeric(78,0) NOT NULL CHECK (quote_amount_raw > 0),
  price_numerator_raw numeric(78,0) NOT NULL CHECK (price_numerator_raw > 0),
  price_denominator_raw numeric(78,0) NOT NULL CHECK (price_denominator_raw > 0),
  pool_fee_token bytea CHECK (pool_fee_token IS NULL OR octet_length(pool_fee_token) = 20),
  pool_fee_amount_raw numeric(78,0) NOT NULL DEFAULT 0 CHECK (pool_fee_amount_raw >= 0),
  platform_fee_token bytea CHECK (platform_fee_token IS NULL OR octet_length(platform_fee_token) = 20),
  platform_fee_amount_raw numeric(78,0) NOT NULL DEFAULT 0 CHECK (platform_fee_amount_raw >= 0),
  creator_fee_token bytea CHECK (creator_fee_token IS NULL OR octet_length(creator_fee_token) = 20),
  creator_fee_amount_raw numeric(78,0) NOT NULL DEFAULT 0 CHECK (creator_fee_amount_raw >= 0),
  reward_fee_token bytea CHECK (reward_fee_token IS NULL OR octet_length(reward_fee_token) = 20),
  reward_fee_amount_raw numeric(78,0) NOT NULL DEFAULT 0 CHECK (reward_fee_amount_raw >= 0),
  block_hash bytea NOT NULL CHECK (octet_length(block_hash) = 32),
  block_number bigint NOT NULL CHECK (block_number >= 0),
  tx_hash bytea NOT NULL CHECK (octet_length(tx_hash) = 32),
  tx_index integer NOT NULL CHECK (tx_index >= 0),
  log_index integer NOT NULL CHECK (log_index >= 0),
  event_ordinal smallint NOT NULL DEFAULT 0 CHECK (event_ordinal >= 0),
  trade_time timestamptz NOT NULL,
  observed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  canonical boolean NOT NULL DEFAULT true,
  orphaned_at timestamptz,
  orphan_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (chain_id, launchpad, launch_id)
    REFERENCES markets(chain_id, launchpad, launch_id),
  FOREIGN KEY (chain_id, block_hash, tx_hash, log_index)
    REFERENCES raw_logs(chain_id, block_hash, tx_hash, log_index),
  CONSTRAINT market_trade_fee_tokens_present CHECK (
    (pool_fee_amount_raw = 0 OR pool_fee_token IS NOT NULL)
    AND (platform_fee_amount_raw = 0 OR platform_fee_token IS NOT NULL)
    AND (creator_fee_amount_raw = 0 OR creator_fee_token IS NOT NULL)
    AND (reward_fee_amount_raw = 0 OR reward_fee_token IS NOT NULL)
  ),
  CONSTRAINT market_trade_orphan_state CHECK (
    (canonical AND orphaned_at IS NULL)
    OR (NOT canonical AND orphaned_at IS NOT NULL)
  )
);

COMMENT ON TABLE market_trade_events IS
  'Append-only QUOTE trade journal. Content is immutable; reorgs only flip canonical/orphan fields.';
COMMENT ON COLUMN market_trade_events.phase IS
  'curve before graduation, pool after graduation.';
COMMENT ON COLUMN market_trade_events.price_numerator_raw IS
  'Exact rational quote-token raw amount per launch-token raw amount.';
COMMENT ON COLUMN market_trade_events.price_denominator_raw IS
  'Exact rational launch-token raw denominator for price_numerator_raw.';

CREATE UNIQUE INDEX market_trade_events_raw_log_unique
  ON market_trade_events(chain_id, block_hash, tx_hash, log_index, event_ordinal);
CREATE UNIQUE INDEX market_trade_events_one_canonical_log
  ON market_trade_events(chain_id, tx_hash, log_index, event_ordinal) WHERE canonical;
CREATE INDEX market_trade_events_market_order
  ON market_trade_events(chain_id, launchpad, launch_id, block_number, tx_index, log_index, event_ordinal)
  WHERE canonical;
CREATE INDEX market_trade_events_market_time
  ON market_trade_events(chain_id, launchpad, launch_id, trade_time DESC, trade_event_id DESC)
  WHERE canonical;
CREATE INDEX market_trade_events_venue_order
  ON market_trade_events(chain_id, venue, block_number, tx_index, log_index, event_ordinal)
  WHERE canonical;
CREATE INDEX market_trade_events_reorg_queue
  ON market_trade_events(chain_id, block_number, block_hash) WHERE NOT canonical;

CREATE TABLE market_live_stats (
  chain_id bigint NOT NULL,
  launchpad bytea NOT NULL CHECK (octet_length(launchpad) = 20),
  launch_id numeric(78,0) NOT NULL,
  last_trade_event_id bigint REFERENCES market_trade_events(trade_event_id),
  last_phase text CHECK (last_phase IS NULL OR last_phase IN ('curve', 'pool')),
  last_trade_type text CHECK (last_trade_type IS NULL OR last_trade_type IN ('buy', 'sell', 'swap')),
  last_block_hash bytea CHECK (last_block_hash IS NULL OR octet_length(last_block_hash) = 32),
  last_block_number bigint CHECK (last_block_number IS NULL OR last_block_number >= 0),
  last_tx_hash bytea CHECK (last_tx_hash IS NULL OR octet_length(last_tx_hash) = 32),
  last_tx_index integer CHECK (last_tx_index IS NULL OR last_tx_index >= 0),
  last_log_index integer CHECK (last_log_index IS NULL OR last_log_index >= 0),
  last_event_ordinal smallint CHECK (last_event_ordinal IS NULL OR last_event_ordinal >= 0),
  last_trade_at timestamptz,
  last_price_numerator_raw numeric(78,0) CHECK (last_price_numerator_raw IS NULL OR last_price_numerator_raw > 0),
  last_price_denominator_raw numeric(78,0) CHECK (last_price_denominator_raw IS NULL OR last_price_denominator_raw > 0),
  total_trade_count bigint NOT NULL DEFAULT 0 CHECK (total_trade_count >= 0),
  buy_trade_count bigint NOT NULL DEFAULT 0 CHECK (buy_trade_count >= 0),
  sell_trade_count bigint NOT NULL DEFAULT 0 CHECK (sell_trade_count >= 0),
  swap_trade_count bigint NOT NULL DEFAULT 0 CHECK (swap_trade_count >= 0),
  curve_trade_count bigint NOT NULL DEFAULT 0 CHECK (curve_trade_count >= 0),
  pool_trade_count bigint NOT NULL DEFAULT 0 CHECK (pool_trade_count >= 0),
  token_volume_raw_total numeric(78,0) NOT NULL DEFAULT 0 CHECK (token_volume_raw_total >= 0),
  quote_volume_raw_total numeric(78,0) NOT NULL DEFAULT 0 CHECK (quote_volume_raw_total >= 0),
  token_volume_raw_24h numeric(78,0) NOT NULL DEFAULT 0 CHECK (token_volume_raw_24h >= 0),
  quote_volume_raw_24h numeric(78,0) NOT NULL DEFAULT 0 CHECK (quote_volume_raw_24h >= 0),
  pool_fees_quote_raw_total numeric(78,0) NOT NULL DEFAULT 0 CHECK (pool_fees_quote_raw_total >= 0),
  platform_fees_quote_raw_total numeric(78,0) NOT NULL DEFAULT 0 CHECK (platform_fees_quote_raw_total >= 0),
  creator_fees_quote_raw_total numeric(78,0) NOT NULL DEFAULT 0 CHECK (creator_fees_quote_raw_total >= 0),
  reward_fees_quote_raw_total numeric(78,0) NOT NULL DEFAULT 0 CHECK (reward_fees_quote_raw_total >= 0),
  rolling_24h_from timestamptz,
  rolling_24h_through timestamptz,
  market_cap_usd numeric,
  liquidity_usd numeric,
  volume_24h_usd numeric,
  stats_as_of timestamptz,
  projection_status text NOT NULL DEFAULT 'live' CHECK (projection_status IN ('live', 'dirty', 'rebuilding')),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (chain_id, launchpad, launch_id),
  FOREIGN KEY (chain_id, launchpad, launch_id)
    REFERENCES markets(chain_id, launchpad, launch_id),
  CHECK (buy_trade_count + sell_trade_count + swap_trade_count = total_trade_count),
  CHECK (curve_trade_count + pool_trade_count = total_trade_count)
);

CREATE INDEX market_live_stats_market_cap
  ON market_live_stats(chain_id, market_cap_usd DESC NULLS LAST, launch_id DESC);
CREATE INDEX market_live_stats_volume_24h
  ON market_live_stats(chain_id, volume_24h_usd DESC NULLS LAST, launch_id DESC);
CREATE INDEX market_live_stats_updated
  ON market_live_stats(chain_id, updated_at DESC);

CREATE TABLE market_candles_1m (
  chain_id bigint NOT NULL,
  launchpad bytea NOT NULL CHECK (octet_length(launchpad) = 20),
  launch_id numeric(78,0) NOT NULL,
  bucket_start timestamptz NOT NULL,
  first_trade_event_id bigint NOT NULL REFERENCES market_trade_events(trade_event_id),
  last_trade_event_id bigint NOT NULL REFERENCES market_trade_events(trade_event_id),
  first_block_number bigint NOT NULL CHECK (first_block_number >= 0),
  first_tx_index integer NOT NULL CHECK (first_tx_index >= 0),
  first_log_index integer NOT NULL CHECK (first_log_index >= 0),
  first_event_ordinal smallint NOT NULL CHECK (first_event_ordinal >= 0),
  last_block_number bigint NOT NULL CHECK (last_block_number >= 0),
  last_tx_index integer NOT NULL CHECK (last_tx_index >= 0),
  last_log_index integer NOT NULL CHECK (last_log_index >= 0),
  last_event_ordinal smallint NOT NULL CHECK (last_event_ordinal >= 0),
  first_phase text NOT NULL CHECK (first_phase IN ('curve', 'pool')),
  last_phase text NOT NULL CHECK (last_phase IN ('curve', 'pool')),
  open_price_numerator_raw numeric(78,0) NOT NULL CHECK (open_price_numerator_raw > 0),
  open_price_denominator_raw numeric(78,0) NOT NULL CHECK (open_price_denominator_raw > 0),
  high_price_numerator_raw numeric(78,0) NOT NULL CHECK (high_price_numerator_raw > 0),
  high_price_denominator_raw numeric(78,0) NOT NULL CHECK (high_price_denominator_raw > 0),
  low_price_numerator_raw numeric(78,0) NOT NULL CHECK (low_price_numerator_raw > 0),
  low_price_denominator_raw numeric(78,0) NOT NULL CHECK (low_price_denominator_raw > 0),
  close_price_numerator_raw numeric(78,0) NOT NULL CHECK (close_price_numerator_raw > 0),
  close_price_denominator_raw numeric(78,0) NOT NULL CHECK (close_price_denominator_raw > 0),
  token_volume_raw numeric(78,0) NOT NULL DEFAULT 0 CHECK (token_volume_raw >= 0),
  quote_volume_raw numeric(78,0) NOT NULL DEFAULT 0 CHECK (quote_volume_raw >= 0),
  trade_count integer NOT NULL DEFAULT 0 CHECK (trade_count >= 0),
  buy_count integer NOT NULL DEFAULT 0 CHECK (buy_count >= 0),
  sell_count integer NOT NULL DEFAULT 0 CHECK (sell_count >= 0),
  swap_count integer NOT NULL DEFAULT 0 CHECK (swap_count >= 0),
  pool_fees_quote_raw numeric(78,0) NOT NULL DEFAULT 0 CHECK (pool_fees_quote_raw >= 0),
  platform_fees_quote_raw numeric(78,0) NOT NULL DEFAULT 0 CHECK (platform_fees_quote_raw >= 0),
  creator_fees_quote_raw numeric(78,0) NOT NULL DEFAULT 0 CHECK (creator_fees_quote_raw >= 0),
  reward_fees_quote_raw numeric(78,0) NOT NULL DEFAULT 0 CHECK (reward_fees_quote_raw >= 0),
  projection_status text NOT NULL DEFAULT 'live' CHECK (projection_status IN ('live', 'dirty', 'rebuilding')),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (chain_id, launchpad, launch_id, bucket_start),
  FOREIGN KEY (chain_id, launchpad, launch_id)
    REFERENCES markets(chain_id, launchpad, launch_id),
  CHECK (buy_count + sell_count + swap_count = trade_count)
);

CREATE INDEX market_candles_1m_market_recent
  ON market_candles_1m(chain_id, launchpad, launch_id, bucket_start DESC);
CREATE INDEX market_candles_1m_dirty
  ON market_candles_1m(chain_id, bucket_start DESC) WHERE projection_status = 'dirty';

CREATE OR REPLACE FUNCTION market_trade_is_at_or_after(
  candidate_block_number bigint,
  candidate_tx_index integer,
  candidate_log_index integer,
  candidate_event_ordinal smallint,
  current_block_number bigint,
  current_tx_index integer,
  current_log_index integer,
  current_event_ordinal smallint
) RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT current_block_number IS NULL
    OR ROW(candidate_block_number, candidate_tx_index, candidate_log_index, candidate_event_ordinal)
      >= ROW(current_block_number, current_tx_index, current_log_index, current_event_ordinal);
$$;

CREATE OR REPLACE FUNCTION market_trade_is_before(
  candidate_block_number bigint,
  candidate_tx_index integer,
  candidate_log_index integer,
  candidate_event_ordinal smallint,
  current_block_number bigint,
  current_tx_index integer,
  current_log_index integer,
  current_event_ordinal smallint
) RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT current_block_number IS NULL
    OR ROW(candidate_block_number, candidate_tx_index, candidate_log_index, candidate_event_ordinal)
      < ROW(current_block_number, current_tx_index, current_log_index, current_event_ordinal);
$$;

CREATE OR REPLACE FUNCTION market_trade_fee_in_quote(
  fee_token bytea,
  fee_amount numeric,
  quote_token bytea
) RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE WHEN fee_token = quote_token THEN fee_amount ELSE 0::numeric END;
$$;

CREATE OR REPLACE FUNCTION enforce_market_trade_immutability()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF (to_jsonb(OLD) - 'canonical' - 'orphaned_at' - 'orphan_reason')
    IS DISTINCT FROM
    (to_jsonb(NEW) - 'canonical' - 'orphaned_at' - 'orphan_reason') THEN
    RAISE EXCEPTION 'market_trade_event_immutable';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER market_trade_events_immutable
BEFORE UPDATE ON market_trade_events
FOR EACH ROW EXECUTE FUNCTION enforce_market_trade_immutability();

CREATE OR REPLACE FUNCTION apply_market_trade_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  market_row markets%ROWTYPE;
  candle_bucket_start timestamptz;
  pool_fee_quote numeric(78,0);
  platform_fee_quote numeric(78,0);
  creator_fee_quote numeric(78,0);
  reward_fee_quote numeric(78,0);
BEGIN
  IF NOT NEW.canonical THEN
    RETURN NEW;
  END IF;

  SELECT * INTO STRICT market_row
  FROM markets
  WHERE chain_id = NEW.chain_id
    AND launchpad = NEW.launchpad
    AND launch_id = NEW.launch_id
  FOR UPDATE;

  candle_bucket_start := date_trunc('minute', NEW.trade_time);
  pool_fee_quote := market_trade_fee_in_quote(NEW.pool_fee_token, NEW.pool_fee_amount_raw, market_row.quote_token);
  platform_fee_quote := market_trade_fee_in_quote(NEW.platform_fee_token, NEW.platform_fee_amount_raw, market_row.quote_token);
  creator_fee_quote := market_trade_fee_in_quote(NEW.creator_fee_token, NEW.creator_fee_amount_raw, market_row.quote_token);
  reward_fee_quote := market_trade_fee_in_quote(NEW.reward_fee_token, NEW.reward_fee_amount_raw, market_row.quote_token);

  INSERT INTO market_live_stats (
    chain_id,
    launchpad,
    launch_id,
    last_trade_event_id,
    last_phase,
    last_trade_type,
    last_block_hash,
    last_block_number,
    last_tx_hash,
    last_tx_index,
    last_log_index,
    last_event_ordinal,
    last_trade_at,
    last_price_numerator_raw,
    last_price_denominator_raw,
    total_trade_count,
    buy_trade_count,
    sell_trade_count,
    swap_trade_count,
    curve_trade_count,
    pool_trade_count,
    token_volume_raw_total,
    quote_volume_raw_total,
    token_volume_raw_24h,
    quote_volume_raw_24h,
    pool_fees_quote_raw_total,
    platform_fees_quote_raw_total,
    creator_fees_quote_raw_total,
    reward_fees_quote_raw_total,
    rolling_24h_from,
    rolling_24h_through,
    stats_as_of,
    projection_status
  ) VALUES (
    NEW.chain_id,
    NEW.launchpad,
    NEW.launch_id,
    NEW.trade_event_id,
    NEW.phase,
    NEW.trade_type,
    NEW.block_hash,
    NEW.block_number,
    NEW.tx_hash,
    NEW.tx_index,
    NEW.log_index,
    NEW.event_ordinal,
    NEW.trade_time,
    NEW.price_numerator_raw,
    NEW.price_denominator_raw,
    1,
    CASE WHEN NEW.trade_type = 'buy' THEN 1 ELSE 0 END,
    CASE WHEN NEW.trade_type = 'sell' THEN 1 ELSE 0 END,
    CASE WHEN NEW.trade_type = 'swap' THEN 1 ELSE 0 END,
    CASE WHEN NEW.phase = 'curve' THEN 1 ELSE 0 END,
    CASE WHEN NEW.phase = 'pool' THEN 1 ELSE 0 END,
    NEW.token_amount_raw,
    NEW.quote_amount_raw,
    CASE WHEN NEW.trade_time >= clock_timestamp() - interval '24 hours' THEN NEW.token_amount_raw ELSE 0 END,
    CASE WHEN NEW.trade_time >= clock_timestamp() - interval '24 hours' THEN NEW.quote_amount_raw ELSE 0 END,
    pool_fee_quote,
    platform_fee_quote,
    creator_fee_quote,
    reward_fee_quote,
    clock_timestamp() - interval '24 hours',
    clock_timestamp(),
    NEW.trade_time,
    'live'
  )
  ON CONFLICT (chain_id, launchpad, launch_id) DO UPDATE
  SET
    last_trade_event_id = CASE
      WHEN market_trade_is_at_or_after(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_live_stats.last_block_number, market_live_stats.last_tx_index, market_live_stats.last_log_index, market_live_stats.last_event_ordinal)
        THEN NEW.trade_event_id
      ELSE market_live_stats.last_trade_event_id
    END,
    last_phase = CASE
      WHEN market_trade_is_at_or_after(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_live_stats.last_block_number, market_live_stats.last_tx_index, market_live_stats.last_log_index, market_live_stats.last_event_ordinal)
        THEN NEW.phase
      ELSE market_live_stats.last_phase
    END,
    last_trade_type = CASE
      WHEN market_trade_is_at_or_after(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_live_stats.last_block_number, market_live_stats.last_tx_index, market_live_stats.last_log_index, market_live_stats.last_event_ordinal)
        THEN NEW.trade_type
      ELSE market_live_stats.last_trade_type
    END,
    last_block_hash = CASE
      WHEN market_trade_is_at_or_after(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_live_stats.last_block_number, market_live_stats.last_tx_index, market_live_stats.last_log_index, market_live_stats.last_event_ordinal)
        THEN NEW.block_hash
      ELSE market_live_stats.last_block_hash
    END,
    last_block_number = CASE
      WHEN market_trade_is_at_or_after(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_live_stats.last_block_number, market_live_stats.last_tx_index, market_live_stats.last_log_index, market_live_stats.last_event_ordinal)
        THEN NEW.block_number
      ELSE market_live_stats.last_block_number
    END,
    last_tx_hash = CASE
      WHEN market_trade_is_at_or_after(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_live_stats.last_block_number, market_live_stats.last_tx_index, market_live_stats.last_log_index, market_live_stats.last_event_ordinal)
        THEN NEW.tx_hash
      ELSE market_live_stats.last_tx_hash
    END,
    last_tx_index = CASE
      WHEN market_trade_is_at_or_after(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_live_stats.last_block_number, market_live_stats.last_tx_index, market_live_stats.last_log_index, market_live_stats.last_event_ordinal)
        THEN NEW.tx_index
      ELSE market_live_stats.last_tx_index
    END,
    last_log_index = CASE
      WHEN market_trade_is_at_or_after(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_live_stats.last_block_number, market_live_stats.last_tx_index, market_live_stats.last_log_index, market_live_stats.last_event_ordinal)
        THEN NEW.log_index
      ELSE market_live_stats.last_log_index
    END,
    last_event_ordinal = CASE
      WHEN market_trade_is_at_or_after(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_live_stats.last_block_number, market_live_stats.last_tx_index, market_live_stats.last_log_index, market_live_stats.last_event_ordinal)
        THEN NEW.event_ordinal
      ELSE market_live_stats.last_event_ordinal
    END,
    last_trade_at = CASE
      WHEN market_trade_is_at_or_after(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_live_stats.last_block_number, market_live_stats.last_tx_index, market_live_stats.last_log_index, market_live_stats.last_event_ordinal)
        THEN NEW.trade_time
      ELSE market_live_stats.last_trade_at
    END,
    last_price_numerator_raw = CASE
      WHEN market_trade_is_at_or_after(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_live_stats.last_block_number, market_live_stats.last_tx_index, market_live_stats.last_log_index, market_live_stats.last_event_ordinal)
        THEN NEW.price_numerator_raw
      ELSE market_live_stats.last_price_numerator_raw
    END,
    last_price_denominator_raw = CASE
      WHEN market_trade_is_at_or_after(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_live_stats.last_block_number, market_live_stats.last_tx_index, market_live_stats.last_log_index, market_live_stats.last_event_ordinal)
        THEN NEW.price_denominator_raw
      ELSE market_live_stats.last_price_denominator_raw
    END,
    total_trade_count = market_live_stats.total_trade_count + 1,
    buy_trade_count = market_live_stats.buy_trade_count + CASE WHEN NEW.trade_type = 'buy' THEN 1 ELSE 0 END,
    sell_trade_count = market_live_stats.sell_trade_count + CASE WHEN NEW.trade_type = 'sell' THEN 1 ELSE 0 END,
    swap_trade_count = market_live_stats.swap_trade_count + CASE WHEN NEW.trade_type = 'swap' THEN 1 ELSE 0 END,
    curve_trade_count = market_live_stats.curve_trade_count + CASE WHEN NEW.phase = 'curve' THEN 1 ELSE 0 END,
    pool_trade_count = market_live_stats.pool_trade_count + CASE WHEN NEW.phase = 'pool' THEN 1 ELSE 0 END,
    token_volume_raw_total = market_live_stats.token_volume_raw_total + NEW.token_amount_raw,
    quote_volume_raw_total = market_live_stats.quote_volume_raw_total + NEW.quote_amount_raw,
    token_volume_raw_24h = market_live_stats.token_volume_raw_24h
      + CASE WHEN NEW.trade_time >= clock_timestamp() - interval '24 hours' THEN NEW.token_amount_raw ELSE 0 END,
    quote_volume_raw_24h = market_live_stats.quote_volume_raw_24h
      + CASE WHEN NEW.trade_time >= clock_timestamp() - interval '24 hours' THEN NEW.quote_amount_raw ELSE 0 END,
    rolling_24h_from = clock_timestamp() - interval '24 hours',
    rolling_24h_through = clock_timestamp(),
    pool_fees_quote_raw_total = market_live_stats.pool_fees_quote_raw_total + pool_fee_quote,
    platform_fees_quote_raw_total = market_live_stats.platform_fees_quote_raw_total + platform_fee_quote,
    creator_fees_quote_raw_total = market_live_stats.creator_fees_quote_raw_total + creator_fee_quote,
    reward_fees_quote_raw_total = market_live_stats.reward_fees_quote_raw_total + reward_fee_quote,
    stats_as_of = GREATEST(coalesce(market_live_stats.stats_as_of, NEW.trade_time), NEW.trade_time),
    projection_status = 'live',
    updated_at = now();

  INSERT INTO market_candles_1m (
    chain_id,
    launchpad,
    launch_id,
    bucket_start,
    first_trade_event_id,
    last_trade_event_id,
    first_block_number,
    first_tx_index,
    first_log_index,
    first_event_ordinal,
    last_block_number,
    last_tx_index,
    last_log_index,
    last_event_ordinal,
    first_phase,
    last_phase,
    open_price_numerator_raw,
    open_price_denominator_raw,
    high_price_numerator_raw,
    high_price_denominator_raw,
    low_price_numerator_raw,
    low_price_denominator_raw,
    close_price_numerator_raw,
    close_price_denominator_raw,
    token_volume_raw,
    quote_volume_raw,
    trade_count,
    buy_count,
    sell_count,
    swap_count,
    pool_fees_quote_raw,
    platform_fees_quote_raw,
    creator_fees_quote_raw,
    reward_fees_quote_raw
  ) VALUES (
    NEW.chain_id,
    NEW.launchpad,
    NEW.launch_id,
    candle_bucket_start,
    NEW.trade_event_id,
    NEW.trade_event_id,
    NEW.block_number,
    NEW.tx_index,
    NEW.log_index,
    NEW.event_ordinal,
    NEW.block_number,
    NEW.tx_index,
    NEW.log_index,
    NEW.event_ordinal,
    NEW.phase,
    NEW.phase,
    NEW.price_numerator_raw,
    NEW.price_denominator_raw,
    NEW.price_numerator_raw,
    NEW.price_denominator_raw,
    NEW.price_numerator_raw,
    NEW.price_denominator_raw,
    NEW.price_numerator_raw,
    NEW.price_denominator_raw,
    NEW.token_amount_raw,
    NEW.quote_amount_raw,
    1,
    CASE WHEN NEW.trade_type = 'buy' THEN 1 ELSE 0 END,
    CASE WHEN NEW.trade_type = 'sell' THEN 1 ELSE 0 END,
    CASE WHEN NEW.trade_type = 'swap' THEN 1 ELSE 0 END,
    pool_fee_quote,
    platform_fee_quote,
    creator_fee_quote,
    reward_fee_quote
  )
  ON CONFLICT (chain_id, launchpad, launch_id, bucket_start) DO UPDATE
  SET
    first_trade_event_id = CASE
      WHEN market_trade_is_before(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_candles_1m.first_block_number, market_candles_1m.first_tx_index, market_candles_1m.first_log_index, market_candles_1m.first_event_ordinal)
        THEN NEW.trade_event_id
      ELSE market_candles_1m.first_trade_event_id
    END,
    last_trade_event_id = CASE
      WHEN market_trade_is_at_or_after(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_candles_1m.last_block_number, market_candles_1m.last_tx_index, market_candles_1m.last_log_index, market_candles_1m.last_event_ordinal)
        THEN NEW.trade_event_id
      ELSE market_candles_1m.last_trade_event_id
    END,
    first_block_number = CASE
      WHEN market_trade_is_before(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_candles_1m.first_block_number, market_candles_1m.first_tx_index, market_candles_1m.first_log_index, market_candles_1m.first_event_ordinal)
        THEN NEW.block_number
      ELSE market_candles_1m.first_block_number
    END,
    first_tx_index = CASE
      WHEN market_trade_is_before(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_candles_1m.first_block_number, market_candles_1m.first_tx_index, market_candles_1m.first_log_index, market_candles_1m.first_event_ordinal)
        THEN NEW.tx_index
      ELSE market_candles_1m.first_tx_index
    END,
    first_log_index = CASE
      WHEN market_trade_is_before(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_candles_1m.first_block_number, market_candles_1m.first_tx_index, market_candles_1m.first_log_index, market_candles_1m.first_event_ordinal)
        THEN NEW.log_index
      ELSE market_candles_1m.first_log_index
    END,
    first_event_ordinal = CASE
      WHEN market_trade_is_before(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_candles_1m.first_block_number, market_candles_1m.first_tx_index, market_candles_1m.first_log_index, market_candles_1m.first_event_ordinal)
        THEN NEW.event_ordinal
      ELSE market_candles_1m.first_event_ordinal
    END,
    last_block_number = CASE
      WHEN market_trade_is_at_or_after(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_candles_1m.last_block_number, market_candles_1m.last_tx_index, market_candles_1m.last_log_index, market_candles_1m.last_event_ordinal)
        THEN NEW.block_number
      ELSE market_candles_1m.last_block_number
    END,
    last_tx_index = CASE
      WHEN market_trade_is_at_or_after(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_candles_1m.last_block_number, market_candles_1m.last_tx_index, market_candles_1m.last_log_index, market_candles_1m.last_event_ordinal)
        THEN NEW.tx_index
      ELSE market_candles_1m.last_tx_index
    END,
    last_log_index = CASE
      WHEN market_trade_is_at_or_after(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_candles_1m.last_block_number, market_candles_1m.last_tx_index, market_candles_1m.last_log_index, market_candles_1m.last_event_ordinal)
        THEN NEW.log_index
      ELSE market_candles_1m.last_log_index
    END,
    last_event_ordinal = CASE
      WHEN market_trade_is_at_or_after(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_candles_1m.last_block_number, market_candles_1m.last_tx_index, market_candles_1m.last_log_index, market_candles_1m.last_event_ordinal)
        THEN NEW.event_ordinal
      ELSE market_candles_1m.last_event_ordinal
    END,
    first_phase = CASE
      WHEN market_trade_is_before(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_candles_1m.first_block_number, market_candles_1m.first_tx_index, market_candles_1m.first_log_index, market_candles_1m.first_event_ordinal)
        THEN NEW.phase
      ELSE market_candles_1m.first_phase
    END,
    last_phase = CASE
      WHEN market_trade_is_at_or_after(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_candles_1m.last_block_number, market_candles_1m.last_tx_index, market_candles_1m.last_log_index, market_candles_1m.last_event_ordinal)
        THEN NEW.phase
      ELSE market_candles_1m.last_phase
    END,
    open_price_numerator_raw = CASE
      WHEN market_trade_is_before(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_candles_1m.first_block_number, market_candles_1m.first_tx_index, market_candles_1m.first_log_index, market_candles_1m.first_event_ordinal)
        THEN NEW.price_numerator_raw
      ELSE market_candles_1m.open_price_numerator_raw
    END,
    open_price_denominator_raw = CASE
      WHEN market_trade_is_before(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_candles_1m.first_block_number, market_candles_1m.first_tx_index, market_candles_1m.first_log_index, market_candles_1m.first_event_ordinal)
        THEN NEW.price_denominator_raw
      ELSE market_candles_1m.open_price_denominator_raw
    END,
    high_price_numerator_raw = CASE
      WHEN NEW.price_numerator_raw * market_candles_1m.high_price_denominator_raw
        > market_candles_1m.high_price_numerator_raw * NEW.price_denominator_raw
        THEN NEW.price_numerator_raw
      ELSE market_candles_1m.high_price_numerator_raw
    END,
    high_price_denominator_raw = CASE
      WHEN NEW.price_numerator_raw * market_candles_1m.high_price_denominator_raw
        > market_candles_1m.high_price_numerator_raw * NEW.price_denominator_raw
        THEN NEW.price_denominator_raw
      ELSE market_candles_1m.high_price_denominator_raw
    END,
    low_price_numerator_raw = CASE
      WHEN NEW.price_numerator_raw * market_candles_1m.low_price_denominator_raw
        < market_candles_1m.low_price_numerator_raw * NEW.price_denominator_raw
        THEN NEW.price_numerator_raw
      ELSE market_candles_1m.low_price_numerator_raw
    END,
    low_price_denominator_raw = CASE
      WHEN NEW.price_numerator_raw * market_candles_1m.low_price_denominator_raw
        < market_candles_1m.low_price_numerator_raw * NEW.price_denominator_raw
        THEN NEW.price_denominator_raw
      ELSE market_candles_1m.low_price_denominator_raw
    END,
    close_price_numerator_raw = CASE
      WHEN market_trade_is_at_or_after(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_candles_1m.last_block_number, market_candles_1m.last_tx_index, market_candles_1m.last_log_index, market_candles_1m.last_event_ordinal)
        THEN NEW.price_numerator_raw
      ELSE market_candles_1m.close_price_numerator_raw
    END,
    close_price_denominator_raw = CASE
      WHEN market_trade_is_at_or_after(NEW.block_number, NEW.tx_index, NEW.log_index, NEW.event_ordinal, market_candles_1m.last_block_number, market_candles_1m.last_tx_index, market_candles_1m.last_log_index, market_candles_1m.last_event_ordinal)
        THEN NEW.price_denominator_raw
      ELSE market_candles_1m.close_price_denominator_raw
    END,
    token_volume_raw = market_candles_1m.token_volume_raw + NEW.token_amount_raw,
    quote_volume_raw = market_candles_1m.quote_volume_raw + NEW.quote_amount_raw,
    trade_count = market_candles_1m.trade_count + 1,
    buy_count = market_candles_1m.buy_count + CASE WHEN NEW.trade_type = 'buy' THEN 1 ELSE 0 END,
    sell_count = market_candles_1m.sell_count + CASE WHEN NEW.trade_type = 'sell' THEN 1 ELSE 0 END,
    swap_count = market_candles_1m.swap_count + CASE WHEN NEW.trade_type = 'swap' THEN 1 ELSE 0 END,
    pool_fees_quote_raw = market_candles_1m.pool_fees_quote_raw + pool_fee_quote,
    platform_fees_quote_raw = market_candles_1m.platform_fees_quote_raw + platform_fee_quote,
    creator_fees_quote_raw = market_candles_1m.creator_fees_quote_raw + creator_fee_quote,
    reward_fees_quote_raw = market_candles_1m.reward_fees_quote_raw + reward_fee_quote,
    projection_status = 'live',
    updated_at = now();

  INSERT INTO outbox(topic, aggregate_id, payload)
  VALUES (
    'market.trade.upsert',
    concat(NEW.chain_id, ':', encode(NEW.launchpad, 'hex'), ':', NEW.launch_id::text),
    jsonb_build_object(
      'type', 'market.trade.upsert',
      'chainId', NEW.chain_id,
      'launchpad', concat('0x', encode(NEW.launchpad, 'hex')),
      'launchId', NEW.launch_id::text,
      'tradeEventId', NEW.trade_event_id,
      'phase', NEW.phase,
      'tradeType', NEW.trade_type,
      'blockNumber', NEW.block_number,
      'txHash', concat('0x', encode(NEW.tx_hash, 'hex')),
      'logIndex', NEW.log_index,
      'eventOrdinal', NEW.event_ordinal,
      'priceNumeratorRaw', NEW.price_numerator_raw::text,
      'priceDenominatorRaw', NEW.price_denominator_raw::text,
      'quoteAmountRaw', NEW.quote_amount_raw::text,
      'tokenAmountRaw', NEW.token_amount_raw::text,
      'poolFeeAmountRaw', NEW.pool_fee_amount_raw::text,
      'platformFeeAmountRaw', NEW.platform_fee_amount_raw::text,
      'creatorFeeAmountRaw', NEW.creator_fee_amount_raw::text,
      'rewardFeeAmountRaw', NEW.reward_fee_amount_raw::text,
      'tradeTime', NEW.trade_time
    )
  );

  RETURN NEW;
END;
$$;

CREATE TRIGGER market_trade_events_apply_insert
AFTER INSERT ON market_trade_events
FOR EACH ROW EXECUTE FUNCTION apply_market_trade_insert();

CREATE OR REPLACE FUNCTION dirty_market_trade_projection()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.canonical IS DISTINCT FROM NEW.canonical THEN
    UPDATE market_live_stats
    SET projection_status = 'dirty', updated_at = now()
    WHERE chain_id = NEW.chain_id
      AND launchpad = NEW.launchpad
      AND launch_id = NEW.launch_id;

    UPDATE market_candles_1m
    SET projection_status = 'dirty', updated_at = now()
    WHERE chain_id = NEW.chain_id
      AND launchpad = NEW.launchpad
      AND launch_id = NEW.launch_id
      AND bucket_start = date_trunc('minute', NEW.trade_time);

    INSERT INTO outbox(topic, aggregate_id, payload)
    VALUES (
      'market.trade.reorg',
      concat(NEW.chain_id, ':', encode(NEW.launchpad, 'hex'), ':', NEW.launch_id::text),
      jsonb_build_object(
        'type', 'market.trade.reorg',
        'chainId', NEW.chain_id,
        'launchpad', concat('0x', encode(NEW.launchpad, 'hex')),
        'launchId', NEW.launch_id::text,
        'tradeEventId', NEW.trade_event_id,
        'canonical', NEW.canonical,
        'blockHash', concat('0x', encode(NEW.block_hash, 'hex')),
        'blockNumber', NEW.block_number,
        'txHash', concat('0x', encode(NEW.tx_hash, 'hex')),
        'logIndex', NEW.log_index,
        'eventOrdinal', NEW.event_ordinal
      )
    );
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER market_trade_events_dirty_projection
AFTER UPDATE OF canonical ON market_trade_events
FOR EACH ROW EXECUTE FUNCTION dirty_market_trade_projection();

CREATE OR REPLACE FUNCTION mark_market_trade_block_noncanonical(
  reorg_chain_id bigint,
  reorg_block_hash bytea,
  reason text DEFAULT 'reorg'
) RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  updated_count integer;
BEGIN
  UPDATE market_trade_events
  SET
    canonical = false,
    orphaned_at = now(),
    orphan_reason = left(reason, 96)
  WHERE chain_id = reorg_chain_id
    AND block_hash = reorg_block_hash
    AND canonical;

  GET DIAGNOSTICS updated_count = ROW_COUNT;
  RETURN updated_count;
END;
$$;

CREATE OR REPLACE FUNCTION rebuild_market_trade_projection(
  target_chain_id bigint,
  target_launchpad bytea,
  target_launch_id numeric,
  rolling_as_of timestamptz DEFAULT now()
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  market_row markets%ROWTYPE;
BEGIN
  SELECT * INTO STRICT market_row
  FROM markets
  WHERE chain_id = target_chain_id
    AND launchpad = target_launchpad
    AND launch_id = target_launch_id
  FOR UPDATE;

  UPDATE market_live_stats
  SET projection_status = 'rebuilding', updated_at = now()
  WHERE chain_id = target_chain_id
    AND launchpad = target_launchpad
    AND launch_id = target_launch_id;

  UPDATE market_candles_1m
  SET projection_status = 'rebuilding', updated_at = now()
  WHERE chain_id = target_chain_id
    AND launchpad = target_launchpad
    AND launch_id = target_launch_id;

  DELETE FROM market_candles_1m
  WHERE chain_id = target_chain_id
    AND launchpad = target_launchpad
    AND launch_id = target_launch_id;

  WITH ordered AS (
    SELECT
      trade.*,
      date_trunc('minute', trade.trade_time) AS bucket_start,
      row_number() OVER (
        PARTITION BY date_trunc('minute', trade.trade_time)
        ORDER BY trade.block_number, trade.tx_index, trade.log_index, trade.event_ordinal, trade.trade_event_id
      ) AS open_rank,
      row_number() OVER (
        PARTITION BY date_trunc('minute', trade.trade_time)
        ORDER BY trade.block_number DESC, trade.tx_index DESC, trade.log_index DESC, trade.event_ordinal DESC, trade.trade_event_id DESC
      ) AS close_rank,
      row_number() OVER (
        PARTITION BY date_trunc('minute', trade.trade_time)
        ORDER BY (trade.price_numerator_raw / trade.price_denominator_raw) DESC, trade.trade_event_id DESC
      ) AS high_rank,
      row_number() OVER (
        PARTITION BY date_trunc('minute', trade.trade_time)
        ORDER BY (trade.price_numerator_raw / trade.price_denominator_raw) ASC, trade.trade_event_id ASC
      ) AS low_rank
    FROM market_trade_events AS trade
    WHERE trade.chain_id = target_chain_id
      AND trade.launchpad = target_launchpad
      AND trade.launch_id = target_launch_id
      AND trade.canonical
  )
  INSERT INTO market_candles_1m (
    chain_id,
    launchpad,
    launch_id,
    bucket_start,
    first_trade_event_id,
    last_trade_event_id,
    first_block_number,
    first_tx_index,
    first_log_index,
    first_event_ordinal,
    last_block_number,
    last_tx_index,
    last_log_index,
    last_event_ordinal,
    first_phase,
    last_phase,
    open_price_numerator_raw,
    open_price_denominator_raw,
    high_price_numerator_raw,
    high_price_denominator_raw,
    low_price_numerator_raw,
    low_price_denominator_raw,
    close_price_numerator_raw,
    close_price_denominator_raw,
    token_volume_raw,
    quote_volume_raw,
    trade_count,
    buy_count,
    sell_count,
    swap_count,
    pool_fees_quote_raw,
    platform_fees_quote_raw,
    creator_fees_quote_raw,
    reward_fees_quote_raw,
    projection_status
  )
  SELECT
    target_chain_id,
    target_launchpad,
    target_launch_id,
    bucket_start,
    max(trade_event_id) FILTER (WHERE open_rank = 1),
    max(trade_event_id) FILTER (WHERE close_rank = 1),
    max(block_number) FILTER (WHERE open_rank = 1),
    max(tx_index) FILTER (WHERE open_rank = 1),
    max(log_index) FILTER (WHERE open_rank = 1),
    max(event_ordinal) FILTER (WHERE open_rank = 1),
    max(block_number) FILTER (WHERE close_rank = 1),
    max(tx_index) FILTER (WHERE close_rank = 1),
    max(log_index) FILTER (WHERE close_rank = 1),
    max(event_ordinal) FILTER (WHERE close_rank = 1),
    max(phase) FILTER (WHERE open_rank = 1),
    max(phase) FILTER (WHERE close_rank = 1),
    max(price_numerator_raw) FILTER (WHERE open_rank = 1),
    max(price_denominator_raw) FILTER (WHERE open_rank = 1),
    max(price_numerator_raw) FILTER (WHERE high_rank = 1),
    max(price_denominator_raw) FILTER (WHERE high_rank = 1),
    max(price_numerator_raw) FILTER (WHERE low_rank = 1),
    max(price_denominator_raw) FILTER (WHERE low_rank = 1),
    max(price_numerator_raw) FILTER (WHERE close_rank = 1),
    max(price_denominator_raw) FILTER (WHERE close_rank = 1),
    coalesce(sum(token_amount_raw), 0),
    coalesce(sum(quote_amount_raw), 0),
    count(*)::integer,
    count(*) FILTER (WHERE trade_type = 'buy')::integer,
    count(*) FILTER (WHERE trade_type = 'sell')::integer,
    count(*) FILTER (WHERE trade_type = 'swap')::integer,
    coalesce(sum(market_trade_fee_in_quote(pool_fee_token, pool_fee_amount_raw, market_row.quote_token)), 0),
    coalesce(sum(market_trade_fee_in_quote(platform_fee_token, platform_fee_amount_raw, market_row.quote_token)), 0),
    coalesce(sum(market_trade_fee_in_quote(creator_fee_token, creator_fee_amount_raw, market_row.quote_token)), 0),
    coalesce(sum(market_trade_fee_in_quote(reward_fee_token, reward_fee_amount_raw, market_row.quote_token)), 0),
    'live'
  FROM ordered
  GROUP BY bucket_start;

  DELETE FROM market_live_stats
  WHERE chain_id = target_chain_id
    AND launchpad = target_launchpad
    AND launch_id = target_launch_id;

  WITH canonical_trades AS (
    SELECT *
    FROM market_trade_events
    WHERE chain_id = target_chain_id
      AND launchpad = target_launchpad
      AND launch_id = target_launch_id
      AND canonical
  ),
  aggregate_stats AS (
    SELECT
      count(*) AS total_trade_count,
      count(*) FILTER (WHERE trade_type = 'buy') AS buy_trade_count,
      count(*) FILTER (WHERE trade_type = 'sell') AS sell_trade_count,
      count(*) FILTER (WHERE trade_type = 'swap') AS swap_trade_count,
      count(*) FILTER (WHERE phase = 'curve') AS curve_trade_count,
      count(*) FILTER (WHERE phase = 'pool') AS pool_trade_count,
      coalesce(sum(token_amount_raw), 0) AS token_volume_raw_total,
      coalesce(sum(quote_amount_raw), 0) AS quote_volume_raw_total,
      coalesce(sum(token_amount_raw) FILTER (WHERE trade_time >= rolling_as_of - interval '24 hours'), 0) AS token_volume_raw_24h,
      coalesce(sum(quote_amount_raw) FILTER (WHERE trade_time >= rolling_as_of - interval '24 hours'), 0) AS quote_volume_raw_24h,
      coalesce(sum(market_trade_fee_in_quote(pool_fee_token, pool_fee_amount_raw, market_row.quote_token)), 0) AS pool_fees_quote_raw_total,
      coalesce(sum(market_trade_fee_in_quote(platform_fee_token, platform_fee_amount_raw, market_row.quote_token)), 0) AS platform_fees_quote_raw_total,
      coalesce(sum(market_trade_fee_in_quote(creator_fee_token, creator_fee_amount_raw, market_row.quote_token)), 0) AS creator_fees_quote_raw_total,
      coalesce(sum(market_trade_fee_in_quote(reward_fee_token, reward_fee_amount_raw, market_row.quote_token)), 0) AS reward_fees_quote_raw_total,
      max(trade_time) AS stats_as_of
    FROM canonical_trades
  ),
  last_trade AS (
    SELECT *
    FROM canonical_trades
    ORDER BY block_number DESC, tx_index DESC, log_index DESC, event_ordinal DESC, trade_event_id DESC
    LIMIT 1
  )
  INSERT INTO market_live_stats (
    chain_id,
    launchpad,
    launch_id,
    last_trade_event_id,
    last_phase,
    last_trade_type,
    last_block_hash,
    last_block_number,
    last_tx_hash,
    last_tx_index,
    last_log_index,
    last_event_ordinal,
    last_trade_at,
    last_price_numerator_raw,
    last_price_denominator_raw,
    total_trade_count,
    buy_trade_count,
    sell_trade_count,
    swap_trade_count,
    curve_trade_count,
    pool_trade_count,
    token_volume_raw_total,
    quote_volume_raw_total,
    token_volume_raw_24h,
    quote_volume_raw_24h,
    pool_fees_quote_raw_total,
    platform_fees_quote_raw_total,
    creator_fees_quote_raw_total,
    reward_fees_quote_raw_total,
    rolling_24h_from,
    rolling_24h_through,
    stats_as_of,
    projection_status
  )
  SELECT
    target_chain_id,
    target_launchpad,
    target_launch_id,
    last_trade.trade_event_id,
    last_trade.phase,
    last_trade.trade_type,
    last_trade.block_hash,
    last_trade.block_number,
    last_trade.tx_hash,
    last_trade.tx_index,
    last_trade.log_index,
    last_trade.event_ordinal,
    last_trade.trade_time,
    last_trade.price_numerator_raw,
    last_trade.price_denominator_raw,
    aggregate_stats.total_trade_count,
    aggregate_stats.buy_trade_count,
    aggregate_stats.sell_trade_count,
    aggregate_stats.swap_trade_count,
    aggregate_stats.curve_trade_count,
    aggregate_stats.pool_trade_count,
    aggregate_stats.token_volume_raw_total,
    aggregate_stats.quote_volume_raw_total,
    aggregate_stats.token_volume_raw_24h,
    aggregate_stats.quote_volume_raw_24h,
    aggregate_stats.pool_fees_quote_raw_total,
    aggregate_stats.platform_fees_quote_raw_total,
    aggregate_stats.creator_fees_quote_raw_total,
    aggregate_stats.reward_fees_quote_raw_total,
    rolling_as_of - interval '24 hours',
    rolling_as_of,
    aggregate_stats.stats_as_of,
    'live'
  FROM aggregate_stats
  LEFT JOIN last_trade ON true;

  INSERT INTO outbox(topic, aggregate_id, payload)
  VALUES (
    'market.trades.rebuilt',
    concat(target_chain_id, ':', encode(target_launchpad, 'hex'), ':', target_launch_id::text),
    jsonb_build_object(
      'type', 'market.trades.rebuilt',
      'chainId', target_chain_id,
      'launchpad', concat('0x', encode(target_launchpad, 'hex')),
      'launchId', target_launch_id::text,
      'asOf', rolling_as_of
    )
  );
END;
$$;

COMMIT;
