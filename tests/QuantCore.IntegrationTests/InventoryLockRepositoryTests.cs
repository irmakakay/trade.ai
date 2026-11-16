using QuantCore.Api.Repositories;
using QuantCore.Contracts.Domain;
using Xunit;

namespace QuantCore.IntegrationTests;

[Collection(PostgresCollection.Name)]
public sealed class InventoryLockRepositoryTests
{
    private readonly PostgresFixture _db;
    private readonly InventoryLockRepository _repo;

    public InventoryLockRepositoryTests(PostgresFixture db)
    {
        _db = db;
        _repo = new InventoryLockRepository(db.ConnectionFactory);
    }

    private static ShareSliceClaimRequest Claim(string symbol, decimal fraction) =>
        new(Guid.NewGuid(), Guid.NewGuid(), symbol, fraction, "LONG_ACCUMULATING");

    [Fact]
    public async Task Claim_Reserves_Fraction_And_Releases_Mutex()
    {
        await _db.ResetAsync();

        var result = await _repo.ClaimSymbolSliceAtomicAsync(Claim("SOLUSDT", 0.40m), 5, CancellationToken.None);

        Assert.True(result.Claimed);
        Assert.Equal(18m, result.ReservedQuantity);
        Assert.Equal(27m, result.RemainingUnallocated);
        Assert.Equal(18m, await _db.ScalarAsync<decimal>(
            "SELECT allocated_quantity FROM portfolio_inventory WHERE symbol = 'SOLUSDT'"));
        Assert.Equal(0L, await _db.ScalarAsync<long>(
            "SELECT COUNT(1) FROM portfolio_inventory WHERE symbol = 'SOLUSDT' AND locked_by_agent IS NOT NULL"));
        Assert.Equal(1L, await _db.ScalarAsync<long>(
            "SELECT COUNT(1) FROM strategy_allocations WHERE symbol = 'SOLUSDT' AND status = 'ACTIVE'"));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-0.1)]
    [InlineData(1.01)]
    public async Task Claim_Rejects_Out_Of_Bounds_Fraction(double fraction)
    {
        var result = await _repo.ClaimSymbolSliceAtomicAsync(Claim("SOLUSDT", (decimal)fraction), 5, CancellationToken.None);

        Assert.False(result.Claimed);
        Assert.Equal("INVALID_FRACTION_BOUNDS", result.Reason);
    }

    [Fact]
    public async Task Claim_Is_Refused_While_Another_Agent_Holds_A_Live_Lock()
    {
        await _db.ResetAsync();
        await _db.ExecuteAsync(
            $"UPDATE portfolio_inventory SET locked_by_agent = '{Guid.NewGuid()}', lock_expires_at = NOW() + interval '1 minute' WHERE symbol = 'BTCUSDT'");

        var result = await _repo.ClaimSymbolSliceAtomicAsync(Claim("BTCUSDT", 0.5m), 5, CancellationToken.None);

        Assert.False(result.Claimed);
        Assert.Equal("SYMBOL_LOCKED_BY_RULING_AGENT", result.Reason);
    }

    [Fact]
    public async Task Claim_Self_Heals_An_Expired_Lock()
    {
        await _db.ResetAsync();
        await _db.ExecuteAsync(
            $"UPDATE portfolio_inventory SET locked_by_agent = '{Guid.NewGuid()}', lock_expires_at = NOW() - interval '1 minute' WHERE symbol = 'BTCUSDT'");

        var result = await _repo.ClaimSymbolSliceAtomicAsync(Claim("BTCUSDT", 0.5m), 5, CancellationToken.None);

        Assert.True(result.Claimed);
        Assert.Equal(0.125m, result.ReservedQuantity);
    }

    [Fact]
    public async Task Claim_Reports_Zero_Unallocated_And_Releases_Lock()
    {
        await _db.ResetAsync();
        await _db.ExecuteAsync("UPDATE portfolio_inventory SET allocated_quantity = total_quantity WHERE symbol = 'ETHUSDT'");

        var result = await _repo.ClaimSymbolSliceAtomicAsync(Claim("ETHUSDT", 0.5m), 5, CancellationToken.None);

        Assert.False(result.Claimed);
        Assert.Equal("ZERO_UNALLOCATED_INVENTORY", result.Reason);
        Assert.Equal(0L, await _db.ScalarAsync<long>(
            "SELECT COUNT(1) FROM portfolio_inventory WHERE symbol = 'ETHUSDT' AND locked_by_agent IS NOT NULL"));
    }

    [Fact]
    public async Task Concurrent_Claims_Never_Overallocate()
    {
        await _db.ResetAsync();

        var results = await Task.WhenAll(Enumerable.Range(0, 8)
            .Select(_ => _repo.ClaimSymbolSliceAtomicAsync(Claim("USDT_CASH", 0.5m), 5, CancellationToken.None)));

        Assert.Contains(results, r => r.Claimed);
        var allocated = await _db.ScalarAsync<decimal>(
            "SELECT allocated_quantity FROM portfolio_inventory WHERE symbol = 'USDT_CASH'");
        Assert.Equal(results.Where(r => r.Claimed).Sum(r => r.ReservedQuantity), allocated);
        Assert.True(allocated <= 10000m);
    }
}
