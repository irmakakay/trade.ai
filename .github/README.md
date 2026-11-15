# CI/CD & Infrastructure Workflows
- `ci-dotnet.yml`: Builds .NET 8, runs xUnit + Coverlet (>=80% gate) + C#/Python JSON schema parity verification.
- `ci-python-nn.yml`: Runs Ruff, Mypy, and Pytest with >=85% coverage gate on `quant_nn_worker`.
- `ci-react-ui.yml`: Runs TypeScript strict check and Vite production bundle verification.
- `ci-infra-smoke.yml`: Boots Postgres 16 + RabbitMQ 3, executes `migrations/runner.py` twice to prove idempotency, and checks metrics.
