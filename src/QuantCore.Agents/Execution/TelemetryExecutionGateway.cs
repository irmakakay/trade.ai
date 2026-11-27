using System.Globalization;
using System.Text.Json;
using Npgsql;

namespace QuantCore.Agents.Execution;

public sealed class TelemetryExecutionGateway : IOrderExecutionGateway
{
    private readonly IOrderExecutionGateway _inner;
    private readonly IConfiguration _config;
    private readonly ILogger<TelemetryExecutionGateway> _logger;

    public string ProviderName => _inner.ProviderName;

    public TelemetryExecutionGateway(
        IOrderExecutionGateway inner,
        IConfiguration config,
        ILogger<TelemetryExecutionGateway> logger)
    {
        _inner = inner;
        _config = config;
        _logger = logger;
    }

    public async Task<ExecutionOrderResult> SubmitOrderAsync(ExecutionOrderRequest request, CancellationToken ct)
    {
        var result = await _inner.SubmitOrderAsync(request, ct);

        decimal executedPrice = ExtractExecutedPrice(result, request.ReferencePrice);
        decimal slippageBps = request.ReferencePrice > 0m
            ? Math.Abs(executedPrice - request.ReferencePrice) / request.ReferencePrice * 10_000m
            : 0m;

        await PersistExecutionOutcomeAsync(request, result, executedPrice, slippageBps, ct);
        return result;
    }

    private static decimal ExtractExecutedPrice(ExecutionOrderResult result, decimal fallbackPrice)
    {
        if (!result.Accepted || result.Mode != "LIVE" || string.IsNullOrWhiteSpace(result.Message))
            return fallbackPrice;

        try
        {
            using var doc = JsonDocument.Parse(result.Message);
            var root = doc.RootElement;
            if (root.TryGetProperty("average_fill_price", out var avgProp) &&
                decimal.TryParse(avgProp.ToString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var parsedAvg) &&
                parsedAvg > 0m)
            {
                return parsedAvg;
            }
            if (root.TryGetProperty("filled_price", out var fillProp) &&
                decimal.TryParse(fillProp.ToString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var parsedFill) &&
                parsedFill > 0m)
            {
                return parsedFill;
            }
        }
        catch
        {
            // Non-JSON message or no fill price field yet
        }

        return fallbackPrice;
    }

    private async Task PersistExecutionOutcomeAsync(
        ExecutionOrderRequest request,
        ExecutionOrderResult result,
        decimal executedPrice,
        decimal slippageBps,
        CancellationToken ct)
    {
        string? connStr = _config.GetConnectionString("DefaultConnection") ?? _config["POSTGRES_CONNECTION_STRING"] ?? _config["POSTGRES_CONNECTION"];
        if (string.IsNullOrWhiteSpace(connStr))
            return;

        try
        {
            await using var conn = new NpgsqlConnection(connStr);
            await conn.OpenAsync(ct);

            const string sql = @"
                INSERT INTO execution_history (
                    client_order_id, provider, execution_mode, symbol, side,
                    requested_qty, reference_price, executed_price, slippage_bps,
                    accepted, venue_order_id, raw_message
                ) VALUES (
                    @client_order_id, @provider, @execution_mode, @symbol, @side,
                    @requested_qty, @reference_price, @executed_price, @slippage_bps,
                    @accepted, @venue_order_id, @raw_message
                );";

            await using var cmd = new NpgsqlCommand(sql, conn);
            cmd.Parameters.AddWithValue("client_order_id", request.ClientOrderId);
            cmd.Parameters.AddWithValue("provider", result.Provider);
            cmd.Parameters.AddWithValue("execution_mode", result.Mode);
            cmd.Parameters.AddWithValue("symbol", request.Symbol);
            cmd.Parameters.AddWithValue("side", request.Side);
            cmd.Parameters.AddWithValue("requested_qty", (result.ExecutedQuantity ?? request.Quantity));
            cmd.Parameters.AddWithValue("reference_price", request.ReferencePrice);
            cmd.Parameters.AddWithValue("executed_price", executedPrice);
            cmd.Parameters.AddWithValue("slippage_bps", slippageBps);
            cmd.Parameters.AddWithValue("accepted", result.Accepted);
            cmd.Parameters.AddWithValue("venue_order_id", (object?)result.VenueOrderId ?? DBNull.Value);
            cmd.Parameters.AddWithValue("raw_message", result.Message);

            await cmd.ExecuteNonQueryAsync(ct);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "[TelemetryGateway] Failed to persist execution_history row for {OrderId}", request.ClientOrderId);
        }
    }
}
