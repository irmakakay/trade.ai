-- V001: Initialize Core Quant Schema with Initialize Semantics

-- 1. Neural Network Binary State Checkpoints
CREATE TABLE IF NOT EXISTS nn_model_checkpoints (
    model_id            UUID PRIMARY KEY,
    version_tag         VARCHAR(64) NOT NULL,
    architecture_config JSONB NOT NULL,
    weights_blob        BYTEA NOT NULL,
    optimizer_blob      BYTEA NOT NULL,
    scaler_blob         BYTEA NOT NULL,
    confidence_score    NUMERIC(6, 4) NOT NULL DEFAULT 0.0000,
    is_promoted_live    BOOLEAN NOT NULL DEFAULT FALSE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 2. Portfolio Inventory & Self-Healing Short-Lived Symbol Mutex
CREATE TABLE IF NOT EXISTS portfolio_inventory (
    symbol              VARCHAR(32) PRIMARY KEY,
    total_quantity      NUMERIC(28, 10) NOT NULL CHECK (total_quantity >= 0),
    allocated_quantity  NUMERIC(28, 10) NOT NULL DEFAULT 0 CHECK (allocated_quantity >= 0),
    directional_bias    VARCHAR(24) NOT NULL DEFAULT 'NEUTRAL',
    locked_by_agent     UUID NULL,
    lock_acquired_at    TIMESTAMPTZ NULL,
    lock_expires_at     TIMESTAMPTZ NULL,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_no_overallocation CHECK (allocated_quantity <= total_quantity)
);

-- 3. Per-Agent Partial Share/Cash Slice Allocations
CREATE TABLE IF NOT EXISTS strategy_allocations (
    allocation_id       UUID PRIMARY KEY,
    symbol              VARCHAR(32) NOT NULL REFERENCES portfolio_inventory(symbol),
    agent_id            UUID NOT NULL,
    strategy_id         UUID NOT NULL,
    reserved_quantity   NUMERIC(28, 10) NOT NULL CHECK (reserved_quantity > 0),
    status              VARCHAR(16) NOT NULL DEFAULT 'ACTIVE',
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 4. K-Replicated Epsilon-Jittered Strategy Pool
CREATE TABLE IF NOT EXISTS strategy_pool (
    pool_instance_id    UUID PRIMARY KEY,
    profile_key         VARCHAR(64) NOT NULL,
    replica_index       INT NOT NULL,
    risk_dial_r         NUMERIC(5, 4) NOT NULL,
    jitter_delta        JSONB NOT NULL,
    strategy_payload    JSONB NOT NULL,
    candidate_symbols   JSONB NOT NULL,
    status              VARCHAR(16) NOT NULL DEFAULT 'AVAILABLE',
    claimed_by_agent_id UUID NULL,
    claimed_at          TIMESTAMPTZ NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_pool_checkout
    ON strategy_pool (profile_key, status, replica_index);

-- 5. Trading Identities, Profiles & Empirical History Ledger
CREATE TABLE IF NOT EXISTS trading_identities (
    identity_id         UUID PRIMARY KEY,
    actor_type          VARCHAR(16) NOT NULL CHECK (actor_type IN ('AGENT', 'CLI_OPERATOR')),
    profile_key         VARCHAR(64) NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS trading_history (
    run_id              UUID PRIMARY KEY,
    pool_instance_id    UUID NULL REFERENCES strategy_pool(pool_instance_id),
    identity_id         UUID NOT NULL REFERENCES trading_identities(identity_id),
    profile_key         VARCHAR(64) NOT NULL,
    replica_index       INT NOT NULL,
    jitter_delta        JSONB NOT NULL,
    executed_moves      JSONB NOT NULL,
    realized_pnl_usdt   NUMERIC(28, 10) NOT NULL DEFAULT 0,
    max_drawdown_pct    NUMERIC(8, 4) NOT NULL DEFAULT 0,
    sharpe_estimate     NUMERIC(8, 4) NOT NULL DEFAULT 0,
    is_generation_winner BOOLEAN NOT NULL DEFAULT FALSE,
    completed_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 6. Market Data Watermarks & Normalization State
CREATE TABLE IF NOT EXISTS market_data_watermarks (
    symbol              VARCHAR(32) NOT NULL,
    timeframe           VARCHAR(16) NOT NULL,
    last_synced_ts_ms   BIGINT NOT NULL DEFAULT 0,
    parquet_path        TEXT NULL,
    rolling_mean        NUMERIC(28, 10) NULL,
    rolling_std         NUMERIC(28, 10) NULL,
    PRIMARY KEY (symbol, timeframe)
);

-- Seed Initial Crypto Inventory (Idempotent ON CONFLICT DO NOTHING)
INSERT INTO portfolio_inventory (symbol, total_quantity, allocated_quantity, directional_bias)
VALUES
    ('USDT_CASH', 10000.0000000000, 0.0000000000, 'NEUTRAL'),
    ('BTCUSDT',   0.2500000000,     0.0000000000, 'NEUTRAL'),
    ('ETHUSDT',   3.5000000000,     0.0000000000, 'NEUTRAL'),
    ('SOLUSDT',   45.0000000000,    0.0000000000, 'NEUTRAL')
ON CONFLICT (symbol) DO NOTHING;
