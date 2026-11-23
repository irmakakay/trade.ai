using System.Globalization;
using System.Text;
using System.Text.Json;
using QuantCore.Agents.Execution.Auth;

namespace QuantCore.Agents.Execution;

public sealed class RevolutXExecutionGateway : IOrderExecutionGateway
{
    private readonly HttpClient _httpClient;
    private readonly RevxAuthenticatorBase _authenticator;
    private readonly IConfiguration _config;
    private readonly ILogger<RevolutXExecutionGateway> _logger;

    public string ProviderName => "REVOLUT_X";

    public RevolutXExecutionGateway(
        HttpClient httpClient,
        RevxAuthenticatorBase authenticator,
        IConfiguration config,
        ILogger<RevolutXExecutionGateway> logger)
    {
        _httpClient = httpClient;
        _authenticator = authenticator;
        _config = config;
        _logger = logger;
    }

    public static string MapToRevxSymbol(string internalSymbol)
    {
        string upper = internalSymbol.Trim().ToUpperInvariant();
        if (upper.Contains('-')) return upper;
        if (upper.EndsWith("USDT", StringComparison.Ordinal))
            return $"{upper[..^4]}-USD";
        if (upper.EndsWith("USDC", StringComparison.Ordinal))
            return $"{upper[..^4]}-USD";
        if (upper.EndsWith("USD", StringComparison.Ordinal) || upper.EndsWith("EUR", StringComparison.Ordinal))
            return $"{upper[..^3]}-{upper[^3..]}";
        return upper;
    }

    public async Task<ExecutionOrderResult> SubmitOrderAsync(ExecutionOrderRequest request, CancellationToken ct)
    {
        bool dryRun = _config.GetValue<bool>("REVX_DRY_RUN", true);
        decimal maxNotionalUsdt = _config.GetValue<decimal>("REVX_MAX_ORDER_USDT", 25m);

        string pair = MapToRevxSymbol(request.Symbol);
        decimal notional = Math.Abs(request.Quantity * request.ReferencePrice);

        if (notional > maxNotionalUsdt)
        {
            _logger.LogWarning(
                "[RevolutXGateway] Blocked order {OrderId}: notional {Notional} exceeds REVX_MAX_ORDER_USDT ({Max})",
                request.ClientOrderId, notional, maxNotionalUsdt);
            return new ExecutionOrderResult(false, ProviderName, dryRun ? "DRY_RUN" : "LIVE", null, "Exceeds REVX_MAX_ORDER_USDT");
        }

        var payloadObj = new
        {
            client_order_id = request.ClientOrderId.ToString("D"),
            symbol = pair,
            side = request.Side.ToLowerInvariant(),
            order_configuration = new
            {
                market = new
                {
                    base_size = request.Quantity.ToString("0.########", CultureInfo.InvariantCulture)
                }
            }
        };

        string minifiedBody = JsonSerializer.Serialize(payloadObj);

        using var httpReq = new HttpRequestMessage(HttpMethod.Post, "/api/1.0/orders")
        {
            Content = new StringContent(minifiedBody, Encoding.UTF8, "application/json")
        };

        using var resp = await _httpClient.SendAsync(httpReq, ct);
        string respText = await resp.Content.ReadAsStringAsync(ct);

        string mode = (dryRun || !_authenticator.HasCredentials) ? "DRY_RUN" : "LIVE";
        if (!resp.IsSuccessStatusCode)
        {
            _logger.LogWarning("[RevolutXGateway] Order rejected ({Status}): {Body}", (int)resp.StatusCode, respText);
            return new ExecutionOrderResult(false, ProviderName, mode, null, $"HTTP {(int)resp.StatusCode}: {respText}");
        }

        return new ExecutionOrderResult(true, ProviderName, mode, request.ClientOrderId.ToString("D"), respText);
    }
}
