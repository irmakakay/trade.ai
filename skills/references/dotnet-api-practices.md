# .NET 8 API Practices
1. Use `readonly record struct` or sealed `record` DTOs in `QuantCore.Contracts`.
2. Propagate `CancellationToken` across all `Npgsql`, `Dapper`, and `RabbitMQ.Client` calls.
3. Serve compiled `quant-ui/dist` directly from Kestrel (`UseStaticFiles`) to maintain 0 extra container overhead.
