using System.Collections.Concurrent;
using Npgsql;

namespace QuantCore.Agents.Execution;

/// <summary>
/// Dual-track router with PostgreSQL-backed distributed live position ledger:
/// - Keeps exploratory replicas, unpromoted models, and synthetic ticks on SimulatedExecutionGateway.
/// - Enforces at most one live position per symbol across all scaled quant-agents containers.
/// - Micro-sizes promoted champion entries to REVX_TARGET_ORDER_USDT below the hard circuit breaker.
/// </summary>
public sealed class PromotedRoutingExecutionGateway : IOrderExecutionGateway
{
    private readonly SimulatedExecutionGateway _simulatedGateway;
    private readonly IOrderExecutionGateway _liveGateway;
    private readonly IConfiguration _config;
    private readonly ILogger<PromotedRoutingExecutionGateway> _logger;
    private readonly string? _pgConnStr;
    private readonly ConcurrentDictionary<string, decimal> _fallbackPositions = new(StringComparer.OrdinalIgnoreCase);
    private int _schemaReady;

    public string ProviderName => _liveGateway.ProviderName;

    public PromotedRoutingExecutionGateway(
        SimulatedExecutionGateway simulatedGateway,
        IOrderExecutionGateway liveGateway,
        IConfiguration config,
        ILogger<PromotedRoutingExecutionGateway> logger)
    {
        _simulatedGateway = simulatedGateway;
        _liveGateway = liveGateway;
        _config = config;
        _logger = logger;
        _pgConnStr = config.GetConnectionString("DefaultConnection")
            ?? config["POSTGRES_CONNECTION_STRING"]
            ?? config["POSTGRES_CONNECTION"];
    }

    public async Task<ExecutionOrderResult> SubmitOrderAsync(ExecutionOrderRequest request, CancellationToken ct)
    {
        if (request.IsSyntheticMarketData)
        {
            return await _simulatedGateway.SubmitOrderAsync(request, ct);
        }

        string side = request.Side.Trim().ToLowerInvariant();
        int championReplica = _config.GetValue<int>("REVX_CHAMPION_REPLICA_INDEX", 1);

        if (request.ReplicaIndex != championReplica)
        {
            return await _simulatedGateway.SubmitOrderAsync(request, ct);
        }

        if (side == "sell")
        {
            var existing = await TryClaimOpenPositionForExitAsync(request.Symbol, ct);
            if (existing is null || existing.Value.Qty <= 0m)
            {
                return await _simulatedGateway.SubmitOrderAsync(request, ct);
            }

            var liveExitReq = request with { Quantity = existing.Value.Qty };
            var exitRes = await _liveGateway.SubmitOrderAsync(liveExitReq, ct);
            if (!exitRes.Accepted)
            {
                await RestorePositionAfterFailedExitAsync(request.Symbol, existing.Value.Qty, existing.Value.EntryPrice, request.ClientOrderId, ct);
            }
            return exitRes;
        }

        decimal minConfidence = _config.GetValue<decimal>("REVX_MIN_LIVE_CONFIDENCE", 0.80m);
        decimal minEdgeBps = _config.GetValue<decimal>("REVX_MIN_EDGE_BPS", 5.0m);
        decimal targetOrderUsdt = _config.GetValue<decimal>("REVX_TARGET_ORDER_USDT", 20m);
        decimal maxOrderUsdt = _config.GetValue<decimal>("REVX_MAX_ORDER_USDT", 25m);
        decimal minDeltaUsdt = _config.GetValue<decimal>("REVX_MIN_DELTA_USDT", 10m);

        if (!request.IsPromotedModel || request.ModelConfidence < minConfidence || request.ExpectedEdgeBps < minEdgeBps)
        {
            return await _simulatedGateway.SubmitOrderAsync(request, ct);
        }

        decimal cappedNotional = Math.Min(targetOrderUsdt, maxOrderUsdt * 0.96m);
        if (request.ReferencePrice <= 0m || cappedNotional < minDeltaUsdt)
        {
            return await _simulatedGateway.SubmitOrderAsync(request, ct);
        }

        decimal liveQty = Math.Round(cappedNotional / request.ReferencePrice, 6, MidpointRounding.ToZero);
        if (liveQty <= 0m || (liveQty * request.ReferencePrice) < minDeltaUsdt)
        {
            return await _simulatedGateway.SubmitOrderAsync(request, ct);
        }

        bool reserved = await TryReserveNewLivePositionAsync(request.Symbol, liveQty, request.ReferencePrice, request.ClientOrderId, ct);
        if (!reserved)
        {
            return await _simulatedGateway.SubmitOrderAsync(request, ct);
        }

        _logger.LogInformation(
            "[PromotedRouter] Routing CHAMPION {Profile}#{Rep} {Side} {Symbol} -> {Provider} | LiveNotional=${Notional:F2} (Conf={Conf:P1}, Edge={Edge:F1}bps, Intent={Intent})",
            request.ProfileKey, request.ReplicaIndex, side, request.Symbol, _liveGateway.ProviderName,
            liveQty * request.ReferencePrice, request.ModelConfidence, request.ExpectedEdgeBps, request.OrderIntent);

        var sizedLiveReq = request with { Quantity = liveQty };
        var res = await _liveGateway.SubmitOrderAsync(sizedLiveReq, ct);
        if (!res.Accepted)
        {
            await ReleaseReservedPositionAsync(request.Symbol, request.ClientOrderId, ct);
        }
        return res;
    }

    private async Task EnsureSchemaAsync(NpgsqlConnection conn, CancellationToken ct)
    {
        if (Volatile.Read(ref _schemaReady) == 1) return;
        const string ddl = @"
            CREATE TABLE IF NOT EXISTS live_venue_positions (
                symbol TEXT PRIMARY KEY,
                provider TEXT NOT NULL,
                open_qty NUMERIC(24,10) NOT NULL,
                avg_entry_price NUMERIC(24,10) NOT NULL,
                last_order_id UUID,
                updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            );";
        await using var cmd = new NpgsqlCommand(ddl, conn);
        await cmd.ExecuteNonQueryAsync(ct);
        Interlocked.Exchange(ref _schemaReady, 1);
    }

    private async Task<bool> TryReserveNewLivePositionAsync(string symbol, decimal qty, decimal price, Guid orderId, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(_pgConnStr))
        {
            return _fallbackPositions.TryAdd(symbol, qty);
        }

        try
        {
            await using var conn = new NpgsqlConnection(_pgConnStr);
            await conn.OpenAsync(ct);
            await EnsureSchemaAsync(conn, ct);

            const string sql = @"
                INSERT INTO live_venue_positions (symbol, provider, open_qty, avg_entry_price, last_order_id, updated_at)
                VALUES (@Symbol, @Provider, @Qty, @Price, @OrderId, NOW())
                ON CONFLICT (symbol) DO NOTHING;";
            await using var cmd = new NpgsqlCommand(sql, conn);
            cmd.Parameters.AddWithValue("Symbol", symbol.ToUpperInvariant());
            cmd.Parameters.AddWithValue("Provider", _liveGateway.ProviderName);
            cmd.Parameters.AddWithValue("Qty", qty);
            cmd.Parameters.AddWithValue("Price", price);
            cmd.Parameters.AddWithValue("OrderId", orderId);

            int inserted = await cmd.ExecuteNonQueryAsync(ct);
            return inserted == 1;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "[PromotedRouter] Failed to reserve Postgres live position for {Symbol}; keeping simulated.", symbol);
            return false;
        }
    }

    private async Task ReleaseReservedPositionAsync(string symbol, Guid orderId, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(_pgConnStr))
        {
            _fallbackPositions.TryRemove(symbol, out _);
            return;
        }

        try
        {
            await using var conn = new NpgsqlConnection(_pgConnStr);
            await conn.OpenAsync(ct);
            const string sql = "DELETE FROM live_venue_positions WHERE symbol = @Symbol AND last_order_id = @OrderId;";
            await using var cmd = new NpgsqlCommand(sql, conn);
            cmd.Parameters.AddWithValue("Symbol", symbol.ToUpperInvariant());
            cmd.Parameters.AddWithValue("OrderId", orderId);
            await cmd.ExecuteNonQueryAsync(ct);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "[PromotedRouter] Failed to rollback reserved position for {Symbol}", symbol);
        }
    }

    private async Task<(decimal Qty, decimal EntryPrice)?> TryClaimOpenPositionForExitAsync(string symbol, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(_pgConnStr))
        {
            return _fallbackPositions.TryRemove(symbol, out decimal qty) ? (qty, 0m) : null;
        }

        try
        {
            await using var conn = new NpgsqlConnection(_pgConnStr);
            await conn.OpenAsync(ct);
            await EnsureSchemaAsync(conn, ct);

            const string sql = @"
                DELETE FROM live_venue_positions
                WHERE symbol = @Symbol
                RETURNING open_qty, avg_entry_price;";
            await using var cmd = new NpgsqlCommand(sql, conn);
            cmd.Parameters.AddWithValue("Symbol", symbol.ToUpperInvariant());
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            if (await reader.ReadAsync(ct))
            {
                return (reader.GetDecimal(0), reader.GetDecimal(1));
            }
            return null;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "[PromotedRouter] Failed to query live position for exit on {Symbol}", symbol);
            return null;
        }
    }

    private async Task RestorePositionAfterFailedExitAsync(string symbol, decimal qty, decimal entryPrice, Guid orderId, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(_pgConnStr))
        {
            _fallbackPositions.TryAdd(symbol, qty);
            return;
        }

        try
        {
            await using var conn = new NpgsqlConnection(_pgConnStr);
            await conn.OpenAsync(ct);
            const string sql = @"
                INSERT INTO live_venue_positions (symbol, provider, open_qty, avg_entry_price, last_order_id, updated_at)
                VALUES (@Symbol, @Provider, @Qty, @Price, @OrderId, NOW())
                ON CONFLICT (symbol) DO NOTHING;";
            await using var cmd = new NpgsqlCommand(sql, conn);
            cmd.Parameters.AddWithValue("Symbol", symbol.ToUpperInvariant());
            cmd.Parameters.AddWithValue("Provider", _liveGateway.ProviderName);
            cmd.Parameters.AddWithValue("Qty", qty);
            cmd.Parameters.AddWithValue("Price", entryPrice);
            cmd.Parameters.AddWithValue("OrderId", orderId);
            await cmd.ExecuteNonQueryAsync(ct);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "[PromotedRouter] Failed to restore live position after rejected exit on {Symbol}", symbol);
        }
    }
}
