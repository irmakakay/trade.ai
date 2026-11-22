using System.Collections.Concurrent;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using QuantCore.Contracts.Domain;

namespace QuantCore.Api.Services;

public sealed class MarketStreamGateway
{
    private readonly ConcurrentDictionary<Guid, Channel<LiveStreamFrame>> _subscribers = new();
    private readonly ConcurrentDictionary<string, decimal> _latestPrices = new();
    private readonly ConcurrentQueue<LiveStreamFrame> _recentEvents = new();
    private readonly ConcurrentDictionary<string, List<double[]>> _ohlcvBySymbol = new();
    private readonly object _ohlcvLock = new();
    private const int MaxCandleWindow = 32;
    private const int MaxBufferedEvents = 30;

    public IReadOnlyDictionary<string, decimal> LatestPrices => _latestPrices;

    public void RecordOhlcvCandle(string symbol, double open, double high, double low, double close, double volume)
    {
        if (string.IsNullOrWhiteSpace(symbol) || close <= 0.0) return;
        lock (_ohlcvLock)
        {
            if (!_ohlcvBySymbol.TryGetValue(symbol, out var list))
            {
                list = new List<double[]>(MaxCandleWindow + 1);
                _ohlcvBySymbol[symbol] = list;
            }
            list.Add(new[] { open, high, low, close, volume });
            while (list.Count > MaxCandleWindow)
            {
                list.RemoveAt(0);
            }
        }
    }

    public Dictionary<string, double[][]> GetOhlcvSnapshot(int limit = MaxCandleWindow)
    {
        int clamped = Math.Clamp(limit, 1, MaxCandleWindow);
        var snap = new Dictionary<string, double[][]>(StringComparer.OrdinalIgnoreCase);
        lock (_ohlcvLock)
        {
            foreach (var (sym, list) in _ohlcvBySymbol)
            {
                int take = Math.Min(clamped, list.Count);
                var arr = new double[take][];
                for (int i = 0; i < take; i++)
                {
                    var src = list[list.Count - take + i];
                    arr[i] = new[] { src[0], src[1], src[2], src[3], src[4] };
                }
                snap[sym] = arr;
            }
        }
        return snap;
    }

    public void PublishFrame(LiveStreamFrame frame)
    {
        if (frame.EventType == "MARKET_TICK" && frame.Price > 0m)
        {
            _latestPrices[frame.Symbol] = frame.Price;
            double p = (double)frame.Price;
            RecordOhlcvCandle(frame.Symbol, p, p * 1.0005, p * 0.9995, p, 1.0);
        }
        else
        {
            _recentEvents.Enqueue(frame);
            while (_recentEvents.Count > MaxBufferedEvents && _recentEvents.TryDequeue(out _)) { }
        }

        foreach (var (_, ch) in _subscribers)
        {
            ch.Writer.TryWrite(frame);
        }
    }

    public async Task HandleDashboardClientAsync(WebSocket ws, CancellationToken ct)
    {
        Guid subId = Guid.NewGuid();
        var channel = Channel.CreateBounded<LiveStreamFrame>(new BoundedChannelOptions(512)
        {
            FullMode = BoundedChannelFullMode.DropOldest
        });
        _subscribers[subId] = channel;

        try
        {
            // Replay recent non-tick agent/evolution events immediately on connect
            foreach (var pastEvent in _recentEvents.ToArray())
            {
                if (ws.State != WebSocketState.Open) break;
                var replayPayload = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(pastEvent));
                await ws.SendAsync(replayPayload, WebSocketMessageType.Text, true, ct);
            }

            await foreach (var frame in channel.Reader.ReadAllAsync(ct))
            {
                if (ws.State != WebSocketState.Open) break;
                var payload = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(frame));
                await ws.SendAsync(payload, WebSocketMessageType.Text, true, ct);
            }
        }
        finally
        {
            _subscribers.TryRemove(subId, out _);
        }
    }
}
