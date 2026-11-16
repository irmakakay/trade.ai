using System.Data;
using Npgsql;
using Testcontainers.PostgreSql;
using Xunit;

namespace QuantCore.IntegrationTests;

public sealed class PostgresFixture : IAsyncLifetime
{
    private readonly PostgreSqlContainer _container = new PostgreSqlBuilder().WithImage("postgres:16-alpine").Build();

    public Func<IDbConnection> ConnectionFactory =>
        () => new NpgsqlConnection(_container.GetConnectionString());

    public async Task InitializeAsync()
    {
        await _container.StartAsync();
        await ExecuteAsync(await File.ReadAllTextAsync(FindMigration()));
    }

    public Task DisposeAsync() => _container.DisposeAsync().AsTask();

    // Truncate in dependency order and re-run the seed so each test starts from V001 state.
    public async Task ResetAsync()
    {
        await ExecuteAsync("TRUNCATE strategy_allocations, trading_history, strategy_pool RESTART IDENTITY CASCADE;");
        await ExecuteAsync(
            "UPDATE portfolio_inventory SET allocated_quantity = 0, directional_bias = 'NEUTRAL', " +
            "locked_by_agent = NULL, lock_acquired_at = NULL, lock_expires_at = NULL;");
    }

    public async Task ExecuteAsync(string sql)
    {
        await using var conn = new NpgsqlConnection(_container.GetConnectionString());
        await conn.OpenAsync();
        await using var cmd = new NpgsqlCommand(sql, conn);
        await cmd.ExecuteNonQueryAsync();
    }

    public async Task<T> ScalarAsync<T>(string sql)
    {
        await using var conn = new NpgsqlConnection(_container.GetConnectionString());
        await conn.OpenAsync();
        await using var cmd = new NpgsqlCommand(sql, conn);
        return (T)(await cmd.ExecuteScalarAsync())!;
    }

    private static string FindMigration()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "QuantCore.sln")))
        {
            dir = dir.Parent;
        }

        return Path.Combine(dir?.FullName ?? throw new DirectoryNotFoundException("QuantCore.sln not found"),
            "migrations", "versions", "V001__initialize_schema.sql");
    }
}

[CollectionDefinition(Name)]
public sealed class PostgresCollection : ICollectionFixture<PostgresFixture>
{
    public const string Name = "postgres";
}
