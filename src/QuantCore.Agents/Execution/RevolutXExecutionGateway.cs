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
        string mode = (dryRun || !_authenticator.HasCredentials) ? "DRY_RUN" : "LIVE";

        if (request.IsSyntheticMarketData)
        {
            _logger.LogWarning(
                "[RevolutXGateway] Blocked order {OrderId} ({Symbol}): synthetic market feed data is prohibited on venue.",
                request.ClientOrderId, request.Symbol);
            return new ExecutionOrderResult(false, ProviderName, mode, null, "Blocked synthetic market tick", request.Quantity);
        }

        decimal maxEntryUsdt = _config.GetValue<decimal>("REVX_MAX_ORDER_USDT", 25m);
        decimal maxExitUsdt = _config.GetValue<decimal>("REVX_MAX_EXIT_USDT", Math.Max(maxEntryUsdt * 4m, 100m));
        decimal makerOffsetBps = _config.GetValue<decimal>("REVX_MAKER_OFFSET_BPS", 2.0m);

        string pair = MapToRevxSymbol(request.Symbol);
        string side = request.Side.Trim().ToLowerInvariant();
        decimal notional = Math.Abs(request.Quantity * request.ReferencePrice);
        decimal applicableCap = side == "sell" ? maxExitUsdt : maxEntryUsdt;

        // Hard non-bypassable circuit breaker (separate generous cap for exits so open positions are never trapped)
        if (notional > applicableCap)
        {
            string capName = side == "sell" ? "REVX_MAX_EXIT_USDT" : "REVX_MAX_ORDER_USDT";
            _logger.LogWarning(
                "[RevolutXGateway] Circuit breaker blocked {Side} order {OrderId}: notional {Notional:F2} exceeds {CapName} ({Max})",
                side, request.ClientOrderId, notional, capName, applicableCap);
            return new ExecutionOrderResult(false, ProviderName, mode, null, $"Exceeds {capName}", request.Quantity);
        }

        bool useMarketOrder = request.OrderIntent.Equals("STOP_LOSS", StringComparison.OrdinalIgnoreCase);
        object orderConfig;

        if (useMarketOrder)
        {
            orderConfig = new
            {
                market = new
                {
                    base_size = request.Quantity.ToString("0.########", CultureInfo.InvariantCulture)
                }
            };
        }
        else
        {
            decimal offsetFactor = Math.Max(0m, makerOffsetBps) / 10_000m;
            decimal passivePrice = side == "buy"
                ? request.ReferencePrice * (1m - offsetFactor)
                : request.ReferencePrice * (1m + offsetFactor);
            int decimals = request.ReferencePrice >= 100m ? 2 : 4;
            passivePrice = Math.Round(passivePrice, decimals, MidpointRounding.AwayFromZero);

            orderConfig = new
            {
                limit = new
                {
                    base_size = request.Quantity.ToString("0.########", CultureInfo.InvariantCulture),
                    price = passivePrice.ToString("0.########", CultureInfo.InvariantCulture),
                    execution_instructions = new[] { "post_only" }
                }
            };
        }

        var payloadObj = new
        {
            client_order_id = request.ClientOrderId.ToString("D"),
            symbol = pair,
            side,
            order_configuration = orderConfig
        };

        string minifiedBody = JsonSerializer.Serialize(payloadObj);

        using var httpReq = new HttpRequestMessage(HttpMethod.Post, "/api/1.0/orders")
        {
            Content = new StringContent(minifiedBody, Encoding.UTF8, "application/json")
        };

        using var resp = await _httpClient.SendAsync(httpReq, ct);
        string respText = await resp.Content.ReadAsStringAsync(ct);

        if (!resp.IsSuccessStatusCode)
        {
            _logger.LogWarning("[RevolutXGateway] Order rejected ({Status}): {Body}", (int)resp.StatusCode, respText);
            return new ExecutionOrderResult(false, ProviderName, mode, null, $"HTTP {(int)resp.StatusCode}: {respText}", request.Quantity);
        }

        return new ExecutionOrderResult(true, ProviderName, mode, request.ClientOrderId.ToString("D"), respText, request.Quantity);
    }
}
