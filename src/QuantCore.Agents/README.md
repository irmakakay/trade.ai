# QuantCore.Agents: Autonomous K-Replica Agent Swarm & Interactive CLI Operator

## 1. Dual-Mode Execution
- **Agent Swarm Mode (`--mode agent`)**: Spawns concurrent $K$-replica agent workers (`AgentSwarmHostedService`) paired with `EpisodeCommandWatcher` (listens for real-time WebSocket `FORCE_EPISODE_RESET` commands that pre-empt tick/duration quotas).
- **Interactive CLI Mode (`--mode cli`)**: Launches a Spectre.Console operator REPL to inspect pool states, claim share slices manually, trigger NN recalculations, or broadcast an immediate `FORCE_EPISODE_RESET` across all running agents.

## 2. Pluggable End-of-Episode Position Settlement (`IPositionSettlementStrategy`)
Configured via the `EPISODE_SETTLEMENT_MODE` environment variable in DI:
- `LIQUIDATE_AND_RELEASE` (`LiquidateAndReleaseStrategy`): Liquidates simulated holdings back to `USDT_CASH` and releases active `strategy_allocations` slices at episode completion.
- `CARRY_POSITIONS` (`CarryPositionsStrategy`): Preserves open asset allocations across episode boundaries while flushing the completed episode's PnL and Sharpe metrics to `trading_history`.

## 3. Running
Agents are an opt-in compose profile so they never consume pool slots during `verify-local.sh`:
```bash
docker compose --profile agents up --build --scale quant-agents=3
docker compose run --rm quant-agents --mode cli   # interactive operator
```
Config (env): `QUANT_API_URL`, `QUANT_API_WS_URL`, `AGENT_PROFILE_KEY`, `EPISODE_SETTLEMENT_MODE`, `EPISODE_MAX_TICKS`, `EPISODE_MAX_SECONDS`.

## 4. Api Integration
Talks only to `QuantCore.Api` over HTTP/WebSocket (`/api/v1/pool/checkout`, `/inventory/claim-slice`, `/episodes/commit`, `/episodes/reset`, `/tasks`, `/stream/live`); never touches Postgres or RabbitMQ directly. Wire contracts live in `QuantCore.Contracts`.
