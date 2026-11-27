using System.Globalization;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using QuantCore.Contracts.Domain;

namespace QuantCore.Api.Services;

public sealed class BinanceMarketFeedHostedService : BackgroundService
{
    private readonly MarketStreamGateway _gateway;
    private readonly IConfiguration _config;
    private readonly ILogger<BinanceMarketFeedHostedService> _logger;

    public BinanceMarketFeedHostedService(
        MarketStreamGateway gateway,
        IConfiguration config,
        ILogger<BinanceMarketFeedHostedService> logger)
    {
        _gateway = gateway;
        _config = config;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        bool forceSynthetic = _config.GetValue<bool>("USE_SYNTHETIC_MARKET_FEED", false);
        string wsUrl = _config["BINANCE_WS_URL"]
            ?? "wss://stream.binance.com:9443/stream?streams=btcusdt@kline_1m/ethusdt@kline_1m/solusdt@kline_1m";

        var buffer = new byte[8192];

        while (!stoppingToken.IsCancellationRequested)
        {
            if (forceSynthetic)
            {
                await RunSyntheticGbmFeedAsync(stoppingToken);
                continue;
            }

            try
            {
                using var ws = new ClientWebSocket();
                using var connectCts = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
                connectCts.CancelAfter(TimeSpan.FromSeconds(5));

                await ws.ConnectAsync(new Uri(wsUrl), connectCts.Token);
                _logger.LogInformation("[BinanceMarketFeed] Connected to live stream: {Url}", wsUrl);

                while (ws.State == WebSocketState.Open && !stoppingToken.IsCancellationRequested)
                {
                    var res = await ws.ReceiveAsync(buffer, stoppingToken);
                    if (res.MessageType == WebSocketMessageType.Close) break;

                    if (TryParseBinanceKlineWithOhlcv(buffer.AsSpan(0, res.Count), out var frame, out var candle))
                    {
                        if (candle is not null)
                        {
                            _gateway.RecordOhlcvCandle(frame.Symbol, candle[0], candle[1], candle[2], candle[3], candle[4]);
                        }
                        _gateway.PublishFrame(frame);
                    }
                }
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogWarning("[BinanceMarketFeed] Live WS unreachable ({Msg}). Running 15s synthetic GBM fallback...", ex.Message);
                using var fallbackCts = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
                fallbackCts.CancelAfter(TimeSpan.FromSeconds(15));
                try
                {
                    await RunSyntheticGbmFeedAsync(fallbackCts.Token);
                }
                catch (OperationCanceledException) when (!stoppingToken.IsCancellationRequested)
                {
                    // 15s synthetic fallback window elapsed; retry live Binance WS
                }
            }
        }
    }


    public static bool TryParseBinanceKlineWithOhlcv(
        ReadOnlySpan<byte> utf8Json,
        out LiveStreamFrame frame,
        out double[]? ohlcv)
    {
        ohlcv = null;
        if (!TryParseBinanceKline(utf8Json, out frame))
            return false;

        try
        {
            using var doc = JsonDocument.Parse(utf8Json.ToArray());
            var root = doc.RootElement;
            var payload = root.TryGetProperty("data", out var dataElem) ? dataElem : root;
            if (payload.TryGetProperty("k", out var kline))
            {
                double c = (double)frame.Price;
                double o = kline.TryGetProperty("o", out var op) && double.TryParse(op.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var ov) ? ov : c;
                double h = kline.TryGetProperty("h", out var hp) && double.TryParse(hp.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var hv) ? hv : Math.Max(o, c);
                double l = kline.TryGetProperty("l", out var lp) && double.TryParse(lp.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var lv) ? lv : Math.Min(o, c);
                double v = kline.TryGetProperty("v", out var vp) && double.TryParse(vp.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var vv) ? vv : 1.0;
                ohlcv = new[] { o, h, l, c, v };
            }
        }
        catch
        {
            // Keep frame even if optional OHLCV fields are absent
        }
        return true;
    }

    public static bool TryParseBinanceKline(ReadOnlySpan<byte> utf8Json, out LiveStreamFrame frame)
    {
        frame = default;
        try
        {
            using var doc = JsonDocument.Parse(utf8Json.ToArray());
            var root = doc.RootElement;
            var payload = root.TryGetProperty("data", out var dataElem) ? dataElem : root;

            if (!payload.TryGetProperty("k", out var kline))
                return false;

            string symbol = kline.GetProperty("s").GetString() ?? "BTCUSDT";
            string closeStr = kline.GetProperty("c").GetString() ?? "0";
            long eventTime = payload.TryGetProperty("E", out var eProp)
                ? eProp.GetInt64()
                : DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

            if (!decimal.TryParse(closeStr, NumberStyles.Any, CultureInfo.InvariantCulture, out decimal price) || price <= 0m)
                return false;

            frame = new LiveStreamFrame("MARKET_TICK", symbol, price, null, null, eventTime);
            return true;
        }
        catch
        {
            return false;
        }
    }

    private async Task RunSyntheticGbmFeedAsync(CancellationToken ct)
    {
        var prices = new Dictionary<string, decimal>
        {
            ["BTCUSDT"] = _gateway.LatestPrices.TryGetValue("BTCUSDT", out var btc) && btc > 0m ? btc : 65000.00m,
            ["ETHUSDT"] = _gateway.LatestPrices.TryGetValue("ETHUSDT", out var eth) && eth > 0m ? eth : 3100.00m,
            ["SOLUSDT"] = _gateway.LatestPrices.TryGetValue("SOLUSDT", out var sol) && sol > 0m ? sol : 75.00m
        };
        var rng = new Random();

        while (!ct.IsCancellationRequested)
        {
            foreach (var sym in prices.Keys.ToArray())
            {
                // Box-Muller normal shock: drift + volatility
                double u1 = 1.0 - rng.NextDouble();
                double u2 = 1.0 - rng.NextDouble();
                double z = Math.Sqrt(-2.0 * Math.Log(u1)) * Math.Sin(2.0 * Math.PI * u2);
                decimal pctMove = (decimal)(0.00005 + 0.0012 * z);

                prices[sym] = Math.Round(Math.Max(0.01m, prices[sym] * (1.0m + pctMove)), 4);
                _gateway.PublishFrame(new LiveStreamFrame(
                    "MARKET_TICK",
                    sym,
                    prices[sym],
                    null,
                    "SYNTHETIC_GBM",
                    DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()));
            }
            try
            {
                await Task.Delay(250, ct);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
    }
}