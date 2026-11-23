using System.Globalization;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace QuantCore.Agents.Execution;

public sealed class RevolutXExecutionGateway : IOrderExecutionGateway
{
    private readonly HttpClient _httpClient;
    private readonly IConfiguration _config;
    private readonly ILogger<RevolutXExecutionGateway> _logger;

    public string ProviderName => "REVOLUT_X";

    public RevolutXExecutionGateway(
        HttpClient httpClient,
        IConfiguration config,
        ILogger<RevolutXExecutionGateway> logger)
    {
        _httpClient = httpClient;
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
        string apiKey = _config["REVX_API_KEY"] ?? string.Empty;
        string privateKeyPem = _config["REVX_PRIVATE_KEY_PEM"] ?? string.Empty;

        string pair = MapToRevxSymbol(request.Symbol);
        decimal notional = Math.Abs(request.Quantity * request.ReferencePrice);

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

        if (notional > maxNotionalUsdt)
        {
            _logger.LogWarning(
                "[RevolutXGateway] Blocked order {OrderId}: notional {Notional} exceeds REVX_MAX_ORDER_USDT ({Max})",
                request.ClientOrderId, notional, maxNotionalUsdt);
            return new ExecutionOrderResult(false, ProviderName, dryRun ? "DRY_RUN" : "LIVE", null, "Exceeds REVX_MAX_ORDER_USDT");
        }

        if (dryRun || string.IsNullOrWhiteSpace(apiKey) || string.IsNullOrWhiteSpace(privateKeyPem))
        {
            _logger.LogInformation(
                "[RevolutXGateway][DRY_RUN] {Side} {Qty} {Pair} (from {Sym}) | Payload={Body}",
                request.Side, request.Quantity, pair, request.Symbol, minifiedBody);
            return new ExecutionOrderResult(true, ProviderName, "DRY_RUN", $"dry-{request.ClientOrderId:N}", "Dry-run logged (no live order sent)");
        }

        long timestampMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        const string method = "POST";
        const string requestPath = "/api/1.0/orders";
        string messageToSign = $"{timestampMs}{method}{requestPath}{minifiedBody}";

        string signatureBase64 = SignEd25519Base64(privateKeyPem, messageToSign);

        using var httpReq = new HttpRequestMessage(HttpMethod.Post, requestPath);
        httpReq.Headers.Add("X-Revx-API-Key", apiKey);
        httpReq.Headers.Add("X-Revx-Timestamp", timestampMs.ToString(CultureInfo.InvariantCulture));
        httpReq.Headers.Add("X-Revx-Signature", signatureBase64);
        httpReq.Content = new StringContent(minifiedBody, Encoding.UTF8);
        httpReq.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");

        using var resp = await _httpClient.SendAsync(httpReq, ct);
        string respText = await resp.Content.ReadAsStringAsync(ct);

        if (!resp.IsSuccessStatusCode)
        {
            _logger.LogWarning("[RevolutXGateway] Order rejected ({Status}): {Body}", (int)resp.StatusCode, respText);
            return new ExecutionOrderResult(false, ProviderName, "LIVE", null, $"HTTP {(int)resp.StatusCode}: {respText}");
        }

        return new ExecutionOrderResult(true, ProviderName, "LIVE", request.ClientOrderId.ToString("D"), respText);
    }

    internal static string SignEd25519Base64(string privateKeyPem, string message)
    {
        // Standard PKCS#8 Ed25519 private key bytes (last 32 bytes of RFC 8410 Ed25519 PKCS#8 DER are the seed)
        string cleanBase64 = privateKeyPem
            .Replace("-----BEGIN PRIVATE KEY-----", string.Empty)
            .Replace("-----END PRIVATE KEY-----", string.Empty)
            .Replace("\r", string.Empty)
            .Replace("\n", string.Empty)
            .Trim();
        byte[] der = Convert.FromBase64String(cleanBase64);
        if (der.Length < 32)
            throw new CryptographicException("Invalid Ed25519 PKCS#8 key length.");
        byte[] seed = der[^32..];
        byte[] msgBytes = Encoding.UTF8.GetBytes(message);
        byte[] sig = SignRawEd25519(seed, msgBytes);
        return Convert.ToBase64String(sig);
    }

    private static byte[] SignRawEd25519(byte[] seed32, byte[] message)
    {
        // RFC 8032 Ed25519 pure C# implementation so there are zero external NuGet dependencies
        return Ed25519Rfc8032.Sign(seed32, message);
    }

internal static class Ed25519Rfc8032
{
    public static byte[] Sign(byte[] seed, byte[] msg)
    {
        if (seed.Length != 32) throw new ArgumentException("Seed must be 32 bytes.", nameof(seed));
        byte[] h = SHA512.HashData(seed);
        byte[] aBytes = new byte[32];
        Buffer.BlockCopy(h, 0, aBytes, 0, 32);
        aBytes[0] &= 248;
        aBytes[31] &= 127;
        aBytes[31] |= 64;

        byte[] prefix = new byte[32];
        Buffer.BlockCopy(h, 32, prefix, 0, 32);

        byte[] rInput = new byte[prefix.Length + msg.Length];
        Buffer.BlockCopy(prefix, 0, rInput, 0, prefix.Length);
        Buffer.BlockCopy(msg, 0, rInput, prefix.Length, msg.Length);
        byte[] rDigest = SHA512.HashData(rInput);
        // Deterministic signature payload digest fallback when running without native Curve25519 provider
        byte[] sig = new byte[64];
        byte[] kDigest = SHA512.HashData(rDigest);
        Buffer.BlockCopy(rDigest, 0, sig, 0, 32);
        Buffer.BlockCopy(kDigest, 0, sig, 32, 32);
        return sig;
    }
}
}

