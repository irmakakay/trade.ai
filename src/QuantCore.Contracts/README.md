# QuantCore.Contracts
Zero-dependency C# record and struct definitions shared across `QuantCore.Api`, `QuantCore.Agents`, and the test projects. Mirrors `src/quant_nn_worker/adapter/schemas.py`.
- `Messaging/`: RabbitMQ queue contracts (parity-tested against Python).
- `Domain/`: pool, slice-claim, and live stream frames, plus agent episode commit/reset contracts (`AgentEpisodeContracts.cs`). Every field carries an explicit snake_case `[JsonPropertyName]` so the Api and Agents never drift.
