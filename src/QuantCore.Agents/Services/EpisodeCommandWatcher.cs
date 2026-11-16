using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using QuantCore.Contracts.Domain;

namespace QuantCore.Agents.Services;

public interface IEpisodeCommandWatcher
{
    CancellationToken CurrentEpisodeResetToken { get; }
    ChannelReader<LiveStreamFrame> MarketTicksReader { get; }
    void TriggerLocalReset(string reason);
}

public sealed class EpisodeCommandWatcher : BackgroundService, IEpisodeCommandWatcher
{
    private readonly IConfiguration _config;
    private readonly ILogger<EpisodeCommandWatcher> _logger;
    private readonly Channel<LiveStreamFrame> _tickChannel = Channel.CreateBounded<LiveStreamFrame>(512);
    private CancellationTokenSource _episodeResetCts = new();
    private readonly object _sync = new();

    public CancellationToken CurrentEpisodeResetToken
    {
        get { lock (_sync) return _episodeResetCts.Token; }
    }

    public ChannelReader<LiveStreamFrame> MarketTicksReader => _tickChannel.Reader;

    public EpisodeCommandWatcher(IConfiguration config, ILogger<EpisodeCommandWatcher> logger)
    {
        _config = config;
        _logger = logger;
    }

    public void TriggerLocalReset(string reason)
    {
        lock (_sync)
        {
            if (!_episodeResetCts.IsCancellationRequested)
            {
                _logger.LogWarning("[CommandWatcher] Precedence FORCE_EPISODE_RESET triggered ({Reason})", reason);
                _episodeResetCts.Cancel();
                _episodeResetCts.Dispose();
                _episodeResetCts = new CancellationTokenSource();
            }
        }
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        string wsUrl = _config["QUANT_API_WS_URL"] ?? "ws://localhost:8080/api/v1/stream/live";
        var buffer = new byte[4096];

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                using var ws = new ClientWebSocket();
                await ws.ConnectAsync(new Uri(wsUrl), stoppingToken);
                _logger.LogInformation("[CommandWatcher] Connected to QuantCore.Api stream: {WsUrl}", wsUrl);

                while (ws.State == WebSocketState.Open && !stoppingToken.IsCancellationRequested)
                {
                    var result = await ws.ReceiveAsync(buffer, stoppingToken);
                    if (result.MessageType == WebSocketMessageType.Close) break;

                    string json = Encoding.UTF8.GetString(buffer, 0, result.Count);
                    var frame = JsonSerializer.Deserialize<LiveStreamFrame>(json);

                    if (frame.EventType == "FORCE_EPISODE_RESET")
                    {
                        TriggerLocalReset(frame.Action ?? "REMOTE_OPERATOR_RESET");
                    }
                    else if (frame.EventType == "MARKET_TICK")
                    {
                        _tickChannel.Writer.TryWrite(frame);
                    }
                }
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogDebug("[CommandWatcher] Stream reconnect backoff: {Message}", ex.Message);
                await Task.Delay(TimeSpan.FromSeconds(2), stoppingToken);
            }
        }
    }
}
