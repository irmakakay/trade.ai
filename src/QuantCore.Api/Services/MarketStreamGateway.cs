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

    public IReadOnlyDictionary<string, decimal> LatestPrices => _latestPrices;

    public void PublishFrame(LiveStreamFrame frame)
    {
        if (frame.EventType == "MARKET_TICK" && frame.Price > 0m)
        {
            _latestPrices[frame.Symbol] = frame.Price;
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