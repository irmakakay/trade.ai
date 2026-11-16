# GitHub Copilot Workspace Instructions (`quant-core`)

## 1. Mandatory Entrypoint (Progressive Disclosure Router)
Before generating code, refactoring, or answering architectural queries in this repository, you **MUST** read and obey the single entrypoint router:
- **Primary Router**: [`skills/SKILL.md`](../skills/SKILL.md)

Do **NOT** eagerly load every file inside `skills/references/`. Follow the lazy-loading routing table in `skills/SKILL.md` and load **only** the specific leaf reference file that matches the directory or domain you are actively modifying:

| Active Workspace Target / Scope | Required Reference Leaf to Load |
| :--- | :--- |
| System boundaries, Docker Compose, or RabbitMQ queues | [`skills/references/architecture-invariants.md`](../skills/references/architecture-invariants.md) |
| `src/QuantCore.Api/**` or `src/QuantCore.Contracts/**` (.NET 8) | [`skills/references/dotnet-api-practices.md`](../skills/references/dotnet-api-practices.md) |
| `src/quant_nn_worker/**` or `src/quant_nn_engine/**` (Python Adapter & PyTorch Brain/Engine) | [`skills/references/python-nn-practices.md`](../skills/references/python-nn-practices.md) |
| `migrations/**` or PostgreSQL lock/pool SQL queries | [`skills/references/postgres-concurrency.md`](../skills/references/postgres-concurrency.md) |
| `src/quant-ui/**` (React 18 + Lightweight Charts WS UI) | [`skills/references/react-realtime-ui.md`](../skills/references/react-realtime-ui.md) |
| `tests/**` or `.github/workflows/**` | [`skills/references/testing-and-cicd.md`](../skills/references/testing-and-cicd.md) |
| Explanations, PR reviews, or trade-off analysis | [`skills/references/communication-style.md`](../skills/references/communication-style.md) |

---

## 2. Non-Negotiable Global Invariants
1. **Token & Output Compression**:
   - No greetings, filler, recaps, or unrequested explanations.
   - Output minimal diffs or direct code blocks. Omit unchanged methods/lines.
   - If requirements are ambiguous, ask at most 2 one-line clarifying questions and halt.
2. **Requirement 0 ($0 Financial Cost)**:
   - Never add paid APIs, cloud SDK dependencies, or non-free market data providers.
   - Historical data uses public `data.binance.vision` archives; live data uses keyless Binance public WebSockets routed exclusively through `QuantCore.Api`.
3. **Strict Service Boundaries**:
   - **`QuantCore.Api` (.NET 8)** owns all PostgreSQL transactions, `FOR UPDATE SKIP LOCKED` strategy pool checkouts, short-lived symbol/USDT slice mutexes, and external market streams.
   - **`quant_nn_worker/adapter/` (Python)** owns RabbitMQ `input_queue` consumption, `output_queue` (`x-max-length: 1`, `drop-head`, plus `message_count == 0` terminal status re-push) state transitions, and Postgres `BYTEA` checkpoint serialization.
   - **`quant_nn_worker/brain/` (PyTorch)** is a pure math engine (`torch`/`numpy` only) with zero database or AMQP imports.
4. **Cross-Language Contract Parity**:
   - Any modification to `src/QuantCore.Contracts/Messaging/QueueContracts.cs` **must** be mirrored 1:1 in `src/quant_nn_worker/adapter/schemas.py` and verified via `tests/QuantCore.Tests/ContractParityTests.cs`.