using QuantCore.Api.Repositories;
using Xunit;

namespace QuantCore.IntegrationTests;

[Collection(PostgresCollection.Name)]
public sealed class StrategyPoolRepositoryTests
{
    private readonly PostgresFixture _db;
    private readonly StrategyPoolRepository _repo;

    public StrategyPoolRepositoryTests(PostgresFixture db)
    {
        _db = db;
        _repo = new StrategyPoolRepository(db.ConnectionFactory);
    }

    private Task SeedSlotAsync(string profile, int replica) => _db.ExecuteAsync($@"
        INSERT INTO strategy_pool (pool_instance_id, profile_key, replica_index, risk_dial_r, jitter_delta, strategy_payload, candidate_symbols)
        VALUES ('{Guid.NewGuid()}', '{profile}', {replica}, 0.5, '{{}}', '{{""k"":1}}', '[""BTCUSDT""]');");

    [Fact]
    public async Task Checkout_Returns_Lowest_Replica_And_Marks_Claimed()
    {
        await _db.ResetAsync();
        await SeedSlotAsync("P", 2);
        await SeedSlotAsync("P", 1);
        var agent = Guid.NewGuid();

        var slot = await _repo.CheckoutNextAvailableSlotAsync(agent, "P", CancellationToken.None);

        Assert.NotNull(slot);
        Assert.Equal(1, slot!.ReplicaIndex);
        Assert.Equal("P", slot.ProfileKey);
        Assert.Equal(1, await _repo.GetAvailablePoolCountAsync(CancellationToken.None));
        Assert.Equal(1L, await _db.ScalarAsync<long>(
            $"SELECT COUNT(1) FROM strategy_pool WHERE status = 'CLAIMED' AND claimed_by_agent_id = '{agent}'"));
    }

    [Fact]
    public async Task Checkout_Returns_Null_When_Profile_Has_No_Available_Slot()
    {
        await _db.ResetAsync();
        await SeedSlotAsync("OTHER", 1);

        var slot = await _repo.CheckoutNextAvailableSlotAsync(Guid.NewGuid(), "P", CancellationToken.None);

        Assert.Null(slot);
    }

    [Fact]
    public async Task Concurrent_Checkouts_Never_Receive_The_Same_Slot()
    {
        await _db.ResetAsync();
        for (var i = 1; i <= 5; i++)
        {
            await SeedSlotAsync("P", i);
        }

        var results = await Task.WhenAll(Enumerable.Range(0, 10)
            .Select(_ => _repo.CheckoutNextAvailableSlotAsync(Guid.NewGuid(), "P", CancellationToken.None)));

        var claimed = results.Where(r => r is not null).Select(r => r!.PoolInstanceId).ToList();
        Assert.Equal(5, claimed.Count);
        Assert.Equal(5, claimed.Distinct().Count());
        Assert.Equal(0, await _repo.GetAvailablePoolCountAsync(CancellationToken.None));
    }
}
