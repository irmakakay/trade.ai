# Automated Test Suites & Contract Parity Gates
- `QuantCore.Tests`: .NET 8 xUnit + NSubstitute + Coverlet suite testing pool checkouts, inventory slice mutexes, RabbitMQ head peeks, and C#/Python wire contract parity.
- `quant_nn_tests`: Python Pytest suite verifying `output_queue` head replacement + `size == 0` fallback, `BYTEA` checkpoint roundtrips, and antithetic $\pm\epsilon$ pool jitter math.
