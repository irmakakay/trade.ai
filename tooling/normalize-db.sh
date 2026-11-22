#!/usr/bin/env bash
set -uo pipefail

# Resolve absolute path to quant-core/ repository root regardless of current working directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

dc() {
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/docker-compose.yml" "$@"
}

echo -e "${CYAN}━━━ [$(date +%H:%M:%S)] Normalizing QuantCore PostgreSQL State ━━━${NC}"

dc exec -T postgres psql -v ON_ERROR_STOP=1 -U quant -d quantcore << 'SQL'
BEGIN;

-- 1. Release any orphaned active slice locks and reset allocated_quantity
UPDATE strategy_allocations
SET status = 'RELEASED'
WHERE status = 'ACTIVE';

UPDATE portfolio_inventory
SET allocated_quantity = 0;

-- 2. Reclaim any orphaned CLAIMED slots back to AVAILABLE
UPDATE strategy_pool
SET status = 'AVAILABLE'
WHERE status = 'CLAIMED';

-- 3. Ensure every profile has exact active replicas (1, 2, 3) in AVAILABLE state
--    If a partial generation left < 3 active slots for a profile, expire the partial set
--    and clone the latest valid parameters for replicas 1..3.
WITH profile_targets(profile_key, default_r, default_sl, default_tp, default_slice) AS (
  VALUES
    ('AGGRESSIVE_BREAKOUT',    0.75, 2.20, 3.20, 0.40),
    ('BALANCED_SWING',         0.50, 1.80, 2.60, 0.30),
    ('CAREFUL_MEAN_REVERSION', 0.25, 1.35, 1.90, 0.20)
),
incomplete_profiles AS (
  SELECT pt.profile_key
  FROM profile_targets pt
  LEFT JOIN strategy_pool sp
    ON sp.profile_key = pt.profile_key AND sp.status = 'AVAILABLE'
  GROUP BY pt.profile_key
  HAVING COUNT(sp.pool_instance_id) <> 3
)
UPDATE strategy_pool
SET status = 'EXPIRED'
WHERE status = 'AVAILABLE'
  AND profile_key IN (SELECT profile_key FROM incomplete_profiles);

WITH profile_targets(profile_key, default_r, default_sl, default_tp, default_slice) AS (
  VALUES
    ('AGGRESSIVE_BREAKOUT',    0.75, 2.20, 3.20, 0.40),
    ('BALANCED_SWING',         0.50, 1.80, 2.60, 0.30),
    ('CAREFUL_MEAN_REVERSION', 0.25, 1.35, 1.90, 0.20)
),
missing_profiles AS (
  SELECT pt.*
  FROM profile_targets pt
  WHERE NOT EXISTS (
    SELECT 1 FROM strategy_pool sp
    WHERE sp.profile_key = pt.profile_key AND sp.status = 'AVAILABLE'
  )
),
replicas(replica_index, jitter_mult) AS (
  VALUES (1, -0.05), (2, 0.00), (3, 0.05)
)
INSERT INTO strategy_pool (
  pool_instance_id,
  profile_key,
  replica_index,
  risk_dial_r,
  status,
  candidate_symbols,
  strategy_payload,
  jitter_delta,
  created_at
)
SELECT
  gen_random_uuid(),
  mp.profile_key,
  r.replica_index,
  mp.default_r,
  'AVAILABLE',
  '["BTCUSDT","ETHUSDT","SOLUSDT"]'::jsonb,
  jsonb_build_object(
    'entry_threshold', 0.60,
    'stop_loss_atr', ROUND((mp.default_sl + r.jitter_mult)::numeric, 4),
    'take_profit_rr', ROUND((mp.default_tp + r.jitter_mult)::numeric, 4),
    'max_slice_claim_pct', mp.default_slice
  ),
  jsonb_build_object('jitter', r.jitter_mult),
  NOW()
FROM missing_profiles mp
CROSS JOIN replicas r;

-- 4. Prune old COMPLETED/EXPIRED strategy_pool rows beyond the latest 30 per profile
WITH ranked_history AS (
  SELECT pool_instance_id,
         ROW_NUMBER() OVER (PARTITION BY profile_key ORDER BY created_at DESC) AS rn
  FROM strategy_pool
  WHERE status IN ('COMPLETED', 'EXPIRED')
)
DELETE FROM strategy_pool
WHERE pool_instance_id IN (
  SELECT pool_instance_id FROM ranked_history WHERE rn > 30
);

COMMIT;
SQL

echo -e "${GREEN}[OK] Database normalized. Current State Audit:${NC}"
dc exec -T postgres psql -U quant -d quantcore -c "
  SELECT profile_key, status, COUNT(*) AS slots
  FROM strategy_pool
  GROUP BY profile_key, status
  ORDER BY profile_key, status;

  SELECT symbol, total_quantity, allocated_quantity
  FROM portfolio_inventory
  ORDER BY symbol;

  SELECT
    (SELECT COUNT(*) FROM trading_history) AS total_episodes,
    (SELECT COUNT(*) FROM nn_model_checkpoints) AS total_checkpoints;
"