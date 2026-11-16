# Testing & CI/CD Standards
1. Coverage gates are per assembly, not one global number:
   - `QuantCore.Contracts` (unit tests, `QuantCore.Tests`): >=80% line coverage, enforced in CI via Coverlet.
   - `QuantCore.Api` (integration tests, `QuantCore.IntegrationTests`): reported but not yet gated. Add `/p:Threshold` just below the first stable CI value, then ratchet it toward 80%.
   - Python (`pytest-cov`): >=65%.
2. Do not mock Npgsql or RabbitMQ to chase coverage. Api repositories and the queue service are tested against real Postgres 16 and RabbitMQ 3 via Testcontainers (requires Docker).
3. Exclude only logic-free code (`Program.cs` wiring) from coverage, never repositories or services.
4. Keep `schema_parity_test` passing so C# `QuantCore.Contracts` and Python `adapter/schemas.py` never drift.
