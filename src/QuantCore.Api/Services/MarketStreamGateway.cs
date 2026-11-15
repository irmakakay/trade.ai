using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using QuantCore.Contracts.Domain;

namespace QuantCore.Api.Services;

public sealed class MarketStreamGateway
{
    private readonly Channel<LiveStreamFrame> _broadcastChannel = Channel.CreateUnbounded<LiveStreamFrame>();

    public void PublishFrame(LiveStreamFrame frame) => _broadcastChannel.Writer.TryWrite(frame);

    public async Task HandleDashboardClientAsync(WebSocket ws, CancellationToken ct)
    {
        await foreach (var frame in _broadcastChannel.Reader.ReadAllAsync(ct))
        {
            if (ws.State != WebSocketState.Open) break;
            var payload = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(frame));
            await ws.SendAsync(payload, WebSocketMessageType.Text, true, ct);
        }
    }
}
