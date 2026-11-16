using System.Net;
using System.Net.Http.Json;
using QuantCore.Contracts.Domain;
using QuantCore.Contracts.Messaging;

namespace QuantCore.Agents.Client;

public sealed class QuantApiClient : IQuantApiClient
{
    private readonly HttpClient _http;

    public QuantApiClient(HttpClient http)
    {
        _http = http;
    }

    public async Task<PoolSlotDto?> CheckoutStrategySlotAsync(Guid agentId, string profileKey, CancellationToken ct)
    {
        var resp = await _http.PostAsJsonAsync(
            "/api/v1/pool/checkout",
            new PoolCheckoutRequest(agentId, profileKey),
            ct);

        if (resp.StatusCode == HttpStatusCode.Conflict)
            return null;

        resp.EnsureSuccessStatusCode();
        return await resp.Content.ReadFromJsonAsync<PoolSlotDto>(cancellationToken: ct);
    }

    public async Task<ShareSliceClaimResult?> ClaimSymbolSliceAsync(ShareSliceClaimRequest request, CancellationToken ct)
    {
        var resp = await _http.PostAsJsonAsync("/api/v1/inventory/claim-slice", request, ct);
        if (resp.StatusCode == HttpStatusCode.Conflict)
            return await resp.Content.ReadFromJsonAsync<ShareSliceClaimResult>(cancellationToken: ct);

        resp.EnsureSuccessStatusCode();
        return await resp.Content.ReadFromJsonAsync<ShareSliceClaimResult>(cancellationToken: ct);
    }

    public async Task<EpisodeCommitResponse?> CommitEpisodeHistoryAsync(EpisodeCommitRequest request, CancellationToken ct)
    {
        var resp = await _http.PostAsJsonAsync("/api/v1/episodes/commit", request, ct);
        resp.EnsureSuccessStatusCode();
        return await resp.Content.ReadFromJsonAsync<EpisodeCommitResponse>(cancellationToken: ct);
    }

    public async Task<bool> BroadcastForceResetAsync(EpisodeResetCommand command, CancellationToken ct)
    {
        var resp = await _http.PostAsJsonAsync("/api/v1/episodes/reset", command, ct);
        return resp.IsSuccessStatusCode;
    }

    public async Task<bool> SubmitTaskAsync(InputTaskMessage task, CancellationToken ct)
    {
        var resp = await _http.PostAsJsonAsync("/api/v1/tasks", task, ct);
        return resp.IsSuccessStatusCode;
    }
}
