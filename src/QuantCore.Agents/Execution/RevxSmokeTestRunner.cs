using System.Text.Json;
using QuantCore.Agents.Execution.Auth;

namespace QuantCore.Agents.Execution;

/// <summary>
/// Strictly read-only Revolut X Ed25519 authentication & account probe.
/// Never invokes POST/DELETE order endpoints.
/// </summary>
public sealed class RevxSmokeTestRunner
{
    private readonly HttpClient _httpClient;
    private readonly RevxAuthenticatorBase _authenticator;
    private readonly IConfiguration _config;

    public RevxSmokeTestRunner(
        HttpClient httpClient,
        RevxAuthenticatorBase authenticator,
        IConfiguration config)
    {
        _httpClient = httpClient;
        _authenticator = authenticator;
        _config = config;
    }

    public async Task<int> RunAsync(CancellationToken ct)
    {
        bool dryRun = _config.GetValue<bool>("REVX_DRY_RUN", true);
        Console.WriteLine("=================================================================");
        Console.WriteLine("  Revolut X Read-Only Ed25519 Auth & Balance Smoke Test");
        Console.WriteLine("=================================================================");
        Console.WriteLine($"Base URL      : {_httpClient.BaseAddress}");
        Console.WriteLine($"Authenticator : {_authenticator.AuthenticatorName}");
        Console.WriteLine($"Credentials   : {(_authenticator.HasCredentials ? "LOADED (API Key + Ed25519 Private Key)" : "MISSING")}");
        Console.WriteLine($"REVX_DRY_RUN  : {dryRun}");
        Console.WriteLine();

        if (!_authenticator.HasCredentials)
        {
            Console.Error.WriteLine("[FAIL] Missing REVX_API_KEY or valid REVX_PRIVATE_KEY_PEM.");
            Console.Error.WriteLine("       Run ./tooling/init-revolut-env.sh to register your Ed25519 public key and save your API key in .env.");
            return 2;
        }

        if (dryRun)
        {
            Console.Error.WriteLine("[WARN] REVX_DRY_RUN=true intercepts outbound requests; pass REVX_DRY_RUN=false for the live read-only GET probe.");
        }

        int failures = 0;

        // 1. GET /api/1.0/balances
        var (balOk, balBody) = await ProbeGetAsync("1/3 Account Balances", "/api/1.0/balances", ct);
        if (balOk)
        {
            PrintBalances(balBody);
        }
        else
        {
            failures++;
        }

        // 2. GET /api/1.0/configuration/fees/tiers
        var (feeOk, feeBody) = await ProbeGetAsync("2/3 Spot Fee Tier", "/api/1.0/configuration/fees/tiers", ct);
        if (feeOk)
        {
            PrintSpotFees(feeBody);
        }
        else
        {
            failures++;
        }

        // 3. GET /api/1.0/orders/active?limit=5 (verifies query-string signing without '?')
        var (ordOk, ordBody) = await ProbeGetAsync("3/3 Active Orders (Query-String Signing)", "/api/1.0/orders/active?limit=5", ct);
        if (ordOk)
        {
            PrintActiveOrders(ordBody);
        }
        else
        {
            failures++;
        }

        Console.WriteLine("=================================================================");
        if (failures == 0)
        {
            Console.WriteLine("[PASS] All 3 read-only Revolut X Ed25519 probes succeeded.");
            return 0;
        }

        Console.Error.WriteLine($"[FAIL] {failures}/3 probes failed. Check HTTP status/message above (401 = key/signature/IP whitelist, 409 = clock skew).");
        return 1;
    }

    private async Task<(bool Ok, string Body)> ProbeGetAsync(string label, string pathAndQuery, CancellationToken ct)
    {
        Console.WriteLine($"--- {label}: GET {pathAndQuery} ---");
        using var req = new HttpRequestMessage(HttpMethod.Get, pathAndQuery);
        using var resp = await _httpClient.SendAsync(req, ct);
        string body = await resp.Content.ReadAsStringAsync(ct);

        if (resp.IsSuccessStatusCode)
        {
            Console.WriteLine($"[OK] HTTP {(int)resp.StatusCode} {resp.ReasonPhrase}");
            return (true, body);
        }

        Console.Error.WriteLine($"[FAIL] HTTP {(int)resp.StatusCode} {resp.ReasonPhrase}");
        Console.Error.WriteLine($"       Response: {body}");
        return (false, body);
    }

    private static void PrintBalances(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Array)
            {
                Console.WriteLine($"  Payload: {json}");
                return;
            }

            int totalAssets = 0;
            int nonZero = 0;
            foreach (var item in doc.RootElement.EnumerateArray())
            {
                totalAssets++;
                string ccy = item.TryGetProperty("currency", out var c) ? c.GetString() ?? "?" : "?";
                string avail = item.TryGetProperty("available", out var a) ? a.GetString() ?? "0" : "0";
                string resv = item.TryGetProperty("reserved", out var r) ? r.GetString() ?? "0" : "0";
                string tot = item.TryGetProperty("total", out var t) ? t.GetString() ?? "0" : "0";

                if (decimal.TryParse(tot, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out var totVal) && totVal > 0m)
                {
                    nonZero++;
                    Console.WriteLine($"  {ccy,-8} available={avail,-16} reserved={resv,-14} total={tot}");
                }
            }
            Console.WriteLine($"  Summary: {nonZero} non-zero balance(s) across {totalAssets} currency entries.");
        }
        catch
        {
            Console.WriteLine($"  Raw: {json}");
        }
        Console.WriteLine();
    }

    private static void PrintSpotFees(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.Array)
            {
                foreach (var group in data.EnumerateArray())
                {
                    string type = group.TryGetProperty("type", out var tp) ? tp.GetString() ?? "?" : "?";
                    if (!type.Equals("spot", StringComparison.OrdinalIgnoreCase)) continue;

                    string curTier = group.TryGetProperty("current_tier", out var ctProp) ? ctProp.ToString() : "null";
                    Console.WriteLine($"  Product=spot | current_tier={curTier}");
                    if (group.TryGetProperty("tiers", out var tiers) && tiers.ValueKind == JsonValueKind.Array)
                    {
                        foreach (var tier in tiers.EnumerateArray())
                        {
                            string tNum = tier.TryGetProperty("tier", out var tn) ? tn.ToString() : "?";
                            string maker = tier.TryGetProperty("maker_fee", out var mf) ? mf.GetString() ?? "?" : "?";
                            string taker = tier.TryGetProperty("taker_fee", out var tf) ? tf.GetString() ?? "?" : "?";
                            Console.WriteLine($"    Tier {tNum}: maker_fee={maker} | taker_fee={taker}");
                            if (tNum == "0" || tNum == curTier) break;
                        }
                    }
                }
            }
        }
        catch
        {
            Console.WriteLine($"  Raw: {json}");
        }
        Console.WriteLine();
    }

    private static void PrintActiveOrders(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.Array)
            {
                Console.WriteLine($"  Active orders returned: {data.GetArrayLength()}");
            }
            else if (doc.RootElement.ValueKind == JsonValueKind.Array)
            {
                Console.WriteLine($"  Active orders returned: {doc.RootElement.GetArrayLength()}");
            }
            else
            {
                Console.WriteLine($"  Payload: {json[..Math.Min(json.Length, 200)]}");
            }
        }
        catch
        {
            Console.WriteLine($"  Raw: {json}");
        }
        Console.WriteLine();
    }
}
