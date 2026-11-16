using System.Collections.Concurrent;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using QuantCore.Contracts.Domain;

namespace QuantCore.Api.Services;

public sealed class MarketStreamGateway
{
    private readonly ConcurrentDictionary<Guid, Channel<LiveStreamFrame>> _clients = new();

    // Fan-out: every connected client (dashboard and agents) receives every frame.
    public void PublishFrame(LiveStreamFrame frame)
    {
        foreach (var channel in _clients.Values)
        {
            channel.Writer.TryWrite(frame);
        }
    }

    public (ChannelReader<LiveStreamFrame> Reader, IDisposable Subscription) Subscribe()
    {
        var id = Guid.NewGuid();
        // Slow clients drop their oldest frames instead of growing memory.
        var channel = Channel.CreateBounded<LiveStreamFrame>(
            new BoundedChannelOptions(1024) { FullMode = BoundedChannelFullMode.DropOldest, SingleReader = true });
        _clients[id] = channel;
        return (channel.Reader, new Unsubscriber(() => _clients.TryRemove(id, out _)));
    }

    public async Task HandleDashboardClientAsync(WebSocket ws, CancellationToken ct)
    {
        var (reader, subscription) = Subscribe();
        using (subscription)
        {
            await foreach (var frame in reader.ReadAllAsync(ct))
            {
                if (ws.State != WebSocketState.Open) break;
                var payload = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(frame));
                await ws.SendAsync(payload, WebSocketMessageType.Text, true, ct);
            }
        }
    }

    private sealed class Unsubscriber(Action onDispose) : IDisposable
    {
        public void Dispose() => onDispose();
    }
}
