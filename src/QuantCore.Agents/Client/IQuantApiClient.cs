using QuantCore.Contracts.Domain;
using QuantCore.Contracts.Messaging;

namespace QuantCore.Agents.Client;

public interface IQuantApiClient
{
    Task<PoolSlotDto?> CheckoutStrategySlotAsync(Guid agentId, string profileKey, CancellationToken ct);
    Task<ShareSliceClaimResult?> ClaimSymbolSliceAsync(ShareSliceClaimRequest request, CancellationToken ct);
    Task<EpisodeCommitResponse?> CommitEpisodeHistoryAsync(EpisodeCommitRequest request, CancellationToken ct);
    Task<bool> BroadcastForceResetAsync(EpisodeResetCommand command, CancellationToken ct);
    Task<bool> SubmitTaskAsync(InputTaskMessage task, CancellationToken ct);
}
