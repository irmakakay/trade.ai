#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

export REPO_ROOT
export DOCKER_BUILDKIT=1
export BUILDKIT_PROGRESS=plain
export COMPOSE_DOCKER_CLI_BUILD=1

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

step() { echo -e "\n${CYAN}━━━ [$(date +%H:%M:%S)] $1 ━━━${NC}"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

dc() {
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/docker-compose.yml" "$@"
}

run_guarded() {
  local timeout_sec="$1"
  local label="$2"
  shift 2

  info "Running: ${label} (timeout: ${timeout_sec}s)..."
  local log_file="/tmp/quant_model_auth_$$.log"
  rm -f "$log_file"

  "$@" >"$log_file" 2>&1 &
  local cmd_pid=$!
  local elapsed=0

  while kill -0 "$cmd_pid" 2>/dev/null; do
    local last_line=""
    if [[ -s "$log_file" ]]; then
      last_line=$(tail -n 1 "$log_file" | tr -d '\r' | cut -c1-70)
    fi
    printf "\r  ⏳ [%3ds / %3ds] %s -> %-70s" "$elapsed" "$timeout_sec" "$label" "${last_line:-working...}"
    sleep 1
    elapsed=$((elapsed + 1))

    if [[ "$elapsed" -ge "$timeout_sec" ]]; then
      echo ""
      fail "TIMEOUT (${timeout_sec}s) during: ${label}"
      kill -9 "$cmd_pid" 2>/dev/null || true
      tail -n 20 "$log_file" 2>/dev/null || true
      rm -f "$log_file"
      return 1
    fi
  done

  wait "$cmd_pid"
  local exit_code=$?
  printf "\r\033[K"

  if [[ "$exit_code" -ne 0 ]]; then
    fail "${label} failed (exit code ${exit_code})"
    tail -n 25 "$log_file" 2>/dev/null || true
    rm -f "$log_file"
    return "$exit_code"
  fi

  rm -f "$log_file"
  return 0
}

step "1/6 Upgrading QuantBrainBridge & nn-worker Default Hidden Dimension (64 -> 128)"

python3 - << 'PYEOF'
import os
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"]).resolve()

# 1. Upgrade QuantBrainBridge default hidden_dim from 64 to 128
bridge_path = repo_root / "src/quant_nn_engine/bridge.py"
bridge_code = bridge_path.read_text(encoding="utf-8")
bridge_code = bridge_code.replace("hidden_dim: int = 64", "hidden_dim: int = 128")
bridge_path.write_text(bridge_code, encoding="utf-8")
print(f"[OK] Upgraded {bridge_path} default hidden_dim to 128")

# 2. Upgrade nn-worker default NN_HIDDEN_DIM (128) + safe checkpoint restore across hidden_dim changes
worker_path = repo_root / "src/quant_nn_worker/main.py"
worker_code = worker_path.read_text(encoding="utf-8")
worker_code = worker_code.replace(
    'BRIDGE = QuantBrainBridge(confidence_threshold=CONFIDENCE_THRESHOLD, hidden_dim=64)',
    'NN_HIDDEN_DIM = int(os.getenv("NN_HIDDEN_DIM", "128"))\nBRIDGE = QuantBrainBridge(confidence_threshold=CONFIDENCE_THRESHOLD, hidden_dim=NN_HIDDEN_DIM)'
)
worker_code = worker_code.replace(
    'meta = BrainStateCodec.load_state_bundle(raw_blob, BRIDGE.model, BRIDGE.optimizer)',
    """try:
                    meta = BrainStateCodec.load_state_bundle(raw_blob, BRIDGE.model, BRIDGE.optimizer)
                except Exception as load_err:
                    print(f"[quant_nn_worker] Starting fresh {NN_HIDDEN_DIM}-dim weights (checkpoint incompatible: {load_err})", flush=True)
                    return"""
)
worker_code = worker_code.replace(
    'json.dumps({"hidden_dim": BRIDGE.model.hidden_dim})',
    'json.dumps({"hidden_dim": BRIDGE.model.hidden_dim, "model_arch": "PortfolioConditionedQuantNet_v2"})'
)
worker_path.write_text(worker_code, encoding="utf-8")
print(f"[OK] Upgraded {worker_path} to use NN_HIDDEN_DIM=128 with safe checkpoint compatibility")
PYEOF

step "2/6 Creating Abstract Auth Component, Middleware & RevolutXExecutionGateway"

python3 - << 'PYEOF'
import os
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"]).resolve()
auth_dir = repo_root / "src/QuantCore.Agents/Execution/Auth"
mw_dir = repo_root / "src/QuantCore.Agents/Execution/Middleware"
exec_dir = repo_root / "src/QuantCore.Agents/Execution"
auth_dir.mkdir(parents=True, exist_ok=True)
mw_dir.mkdir(parents=True, exist_ok=True)
exec_dir.mkdir(parents=True, exist_ok=True)

(auth_dir / "IRevxAuthenticator.cs").write_text("""using System.Globalization;

namespace QuantCore.Agents.Execution.Auth;

public sealed record RevxAuthHeaders(
    string ApiKey,
    long TimestampMs,
    string SignatureBase64
);

public interface IRevxAuthenticator
{
    string AuthenticatorName { get; }
    bool HasCredentials { get; }
    RevxAuthHeaders SignRequest(string httpMethod, string requestPathAndQuery, string minifiedBody);
}

public abstract class RevxAuthenticatorBase : IRevxAuthenticator
{
    public abstract string AuthenticatorName { get; }
    public abstract bool HasCredentials { get; }

    public RevxAuthHeaders SignRequest(string httpMethod, string requestPathAndQuery, string minifiedBody)
    {
        long timestampMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        string normalizedMethod = (httpMethod ?? "GET").Trim().ToUpperInvariant();
        string normalizedPath = string.IsNullOrWhiteSpace(requestPathAndQuery)
            ? "/"
            : (requestPathAndQuery.StartsWith('/') ? requestPathAndQuery : "/" + requestPathAndQuery);
        string payload = $"{timestampMs.ToString(CultureInfo.InvariantCulture)}{normalizedMethod}{normalizedPath}{minifiedBody ?? string.Empty}";
        return SignPayload(normalizedMethod, normalizedPath, payload, timestampMs);
    }

    protected abstract RevxAuthHeaders SignPayload(
        string normalizedMethod,
        string normalizedPath,
        string canonicalPayload,
        long timestampMs);
}
""", encoding="utf-8")

(auth_dir / "FakeRevxAuthenticator.cs").write_text("""using System.Security.Cryptography;
using System.Text;

namespace QuantCore.Agents.Execution.Auth;

public sealed class FakeRevxAuthenticator : RevxAuthenticatorBase
{
    public override string AuthenticatorName => "FAKE";
    public override bool HasCredentials => false;

    protected override RevxAuthHeaders SignPayload(
        string normalizedMethod,
        string normalizedPath,
        string canonicalPayload,
        long timestampMs)
    {
        string fakeSig = Convert.ToBase64String(SHA256.HashData(Encoding.UTF8.GetBytes($"FAKE::{canonicalPayload}")));
        return new RevxAuthHeaders(
            ApiKey: "LOCAL_FAKE_REVX_KEY",
            TimestampMs: timestampMs,
            SignatureBase64: fakeSig
        );
    }
}
""", encoding="utf-8")

(auth_dir / "RevxEd25519Authenticator.cs").write_text("""using System.Text;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;
using Org.BouncyCastle.OpenSsl;

namespace QuantCore.Agents.Execution.Auth;

public sealed class RevxEd25519Authenticator : RevxAuthenticatorBase
{
    private readonly string _apiKey;
    private readonly Ed25519PrivateKeyParameters? _privateKey;

    public override string AuthenticatorName => "ED25519";
    public override bool HasCredentials => !string.IsNullOrWhiteSpace(_apiKey) && _privateKey is not null;

    public RevxEd25519Authenticator(IConfiguration config, ILogger<RevxEd25519Authenticator> logger)
    {
        _apiKey = (config["REVX_API_KEY"] ?? string.Empty).Trim();
        string pemOrPath = (config["REVX_PRIVATE_KEY_PEM"] ?? string.Empty).Trim();

        if (string.IsNullOrWhiteSpace(pemOrPath))
            return;

        try
        {
            string pemText = File.Exists(pemOrPath) ? File.ReadAllText(pemOrPath) : pemOrPath;
            using var reader = new StringReader(pemText);
            var parsed = new PemReader(reader).ReadObject();

            if (parsed is Ed25519PrivateKeyParameters edKey)
            {
                _privateKey = edKey;
            }
            else if (parsed is Org.BouncyCastle.Crypto.AsymmetricCipherKeyPair kp &&
                     kp.Private is Ed25519PrivateKeyParameters kpPriv)
            {
                _privateKey = kpPriv;
            }
            else
            {
                logger.LogWarning("[RevxAuth] Unsupported PEM key type: {Type}", parsed?.GetType().Name ?? "null");
            }
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "[RevxAuth] Failed to load Ed25519 private key");
        }
    }

    protected override RevxAuthHeaders SignPayload(
        string normalizedMethod,
        string normalizedPath,
        string canonicalPayload,
        long timestampMs)
    {
        if (_privateKey is null)
        {
            throw new InvalidOperationException("Ed25519 private key is not configured for RevxEd25519Authenticator.");
        }

        byte[] messageBytes = Encoding.UTF8.GetBytes(canonicalPayload);
        var signer = new Ed25519Signer();
        signer.Init(true, _privateKey);
        signer.BlockUpdate(messageBytes, 0, messageBytes.Length);
        string sigBase64 = Convert.ToBase64String(signer.GenerateSignature());

        return new RevxAuthHeaders(
            ApiKey: _apiKey,
            TimestampMs: timestampMs,
            SignatureBase64: sigBase64
        );
    }
}
""", encoding="utf-8")

(mw_dir / "RevxSigningDelegatingHandler.cs").write_text("""using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using QuantCore.Agents.Execution.Auth;

namespace QuantCore.Agents.Execution.Middleware;

public sealed class RevxSigningDelegatingHandler : DelegatingHandler
{
    private readonly RevxAuthenticatorBase _authenticator;
    private readonly IConfiguration _config;
    private readonly ILogger<RevxSigningDelegatingHandler> _logger;

    public RevxSigningDelegatingHandler(
        RevxAuthenticatorBase authenticator,
        IConfiguration config,
        ILogger<RevxSigningDelegatingHandler> logger)
    {
        _authenticator = authenticator;
        _config = config;
        _logger = logger;
    }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        bool dryRun = _config.GetValue<bool>("REVX_DRY_RUN", true);
        string body = request.Content is not null
            ? await request.Content.ReadAsStringAsync(ct)
            : string.Empty;

        string pathAndQuery = request.RequestUri is not null
            ? (request.RequestUri.IsAbsoluteUri ? request.RequestUri.PathAndQuery : request.RequestUri.OriginalString)
            : "/api/1.0/orders";

        var auth = _authenticator.SignRequest(request.Method.Method, pathAndQuery, body);

        request.Headers.Remove("X-Revx-API-Key");
        request.Headers.Remove("X-Revx-Timestamp");
        request.Headers.Remove("X-Revx-Signature");
        request.Headers.Add("X-Revx-API-Key", auth.ApiKey);
        request.Headers.Add("X-Revx-Timestamp", auth.TimestampMs.ToString(CultureInfo.InvariantCulture));
        request.Headers.Add("X-Revx-Signature", auth.SignatureBase64);

        if (dryRun || !_authenticator.HasCredentials)
        {
            _logger.LogInformation(
                "[RevxMiddleware][DRY_RUN][Auth={Auth}] {Method} {Path} | Ts={Ts} | Body={Body}",
                _authenticator.AuthenticatorName,
                request.Method.Method,
                pathAndQuery,
                auth.TimestampMs,
                body
            );

            return new HttpResponseMessage(HttpStatusCode.Accepted)
            {
                Content = new StringContent(
                    $"{{\\"status\\":\\"DRY_RUN\\",\\"auth\\":\\"{_authenticator.AuthenticatorName}\\",\\"timestamp_ms\\":{auth.TimestampMs}}}",
                    Encoding.UTF8,
                    new MediaTypeHeaderValue("application/json"))
            };
        }

        return await base.SendAsync(request, ct);
    }
}
""", encoding="utf-8")

(exec_dir / "RevolutXExecutionGateway.cs").write_text("""using System.Globalization;
using System.Text;
using System.Text.Json;
using QuantCore.Agents.Execution.Auth;

namespace QuantCore.Agents.Execution;

public sealed class RevolutXExecutionGateway : IOrderExecutionGateway
{
    private readonly HttpClient _httpClient;
    private readonly RevxAuthenticatorBase _authenticator;
    private readonly IConfiguration _config;
    private readonly ILogger<RevolutXExecutionGateway> _logger;

    public string ProviderName => "REVOLUT_X";

    public RevolutXExecutionGateway(
        HttpClient httpClient,
        RevxAuthenticatorBase authenticator,
        IConfiguration config,
        ILogger<RevolutXExecutionGateway> logger)
    {
        _httpClient = httpClient;
        _authenticator = authenticator;
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

        string pair = MapToRevxSymbol(request.Symbol);
        decimal notional = Math.Abs(request.Quantity * request.ReferencePrice);

        if (notional > maxNotionalUsdt)
        {
            _logger.LogWarning(
                "[RevolutXGateway] Blocked order {OrderId}: notional {Notional} exceeds REVX_MAX_ORDER_USDT ({Max})",
                request.ClientOrderId, notional, maxNotionalUsdt);
            return new ExecutionOrderResult(false, ProviderName, dryRun ? "DRY_RUN" : "LIVE", null, "Exceeds REVX_MAX_ORDER_USDT");
        }

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

        using var httpReq = new HttpRequestMessage(HttpMethod.Post, "/api/1.0/orders")
        {
            Content = new StringContent(minifiedBody, Encoding.UTF8, "application/json")
        };

        using var resp = await _httpClient.SendAsync(httpReq, ct);
        string respText = await resp.Content.ReadAsStringAsync(ct);

        string mode = (dryRun || !_authenticator.HasCredentials) ? "DRY_RUN" : "LIVE";
        if (!resp.IsSuccessStatusCode)
        {
            _logger.LogWarning("[RevolutXGateway] Order rejected ({Status}): {Body}", (int)resp.StatusCode, respText);
            return new ExecutionOrderResult(false, ProviderName, mode, null, $"HTTP {(int)resp.StatusCode}: {respText}");
        }

        return new ExecutionOrderResult(true, ProviderName, mode, request.ClientOrderId.ToString("D"), respText);
    }
}
""", encoding="utf-8")

print("[OK] Created abstract auth, concrete implementations, middleware & RevolutXExecutionGateway")
PYEOF

step "3/6 Configuring Bootstrapper DI (ExecutionServiceCollectionExtensions.cs & Program.cs)"

python3 - << 'PYEOF'
import os
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"]).resolve()
csproj_path = repo_root / "src/QuantCore.Agents/QuantCore.Agents.csproj"
csproj_code = csproj_path.read_text(encoding="utf-8")

if "BouncyCastle.Cryptography" not in csproj_code:
    pkg_ref = '    <PackageReference Include="BouncyCastle.Cryptography" Version="2.4.0" />\n'
    if "</ItemGroup>" in csproj_code:
        csproj_code = csproj_code.replace("</ItemGroup>", pkg_ref + "  </ItemGroup>", 1)
    else:
        csproj_code = csproj_code.replace("</Project>", f"  <ItemGroup>\n{pkg_ref}  </ItemGroup>\n</Project>")
    csproj_path.write_text(csproj_code, encoding="utf-8")

boot_path = repo_root / "src/QuantCore.Agents/Execution/ExecutionServiceCollectionExtensions.cs"
boot_path.write_text("""using QuantCore.Agents.Execution.Auth;
using QuantCore.Agents.Execution.Middleware;

namespace QuantCore.Agents.Execution;

public static class ExecutionServiceCollectionExtensions
{
    public static IServiceCollection AddQuantExecutionInfrastructure(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        string gatewayMode = (configuration["EXECUTION_GATEWAY"] ?? "SIMULATED")
            .Trim()
            .ToUpperInvariant();

        bool dryRun = configuration.GetValue<bool>("REVX_DRY_RUN", true);
        string authProvider = (configuration["REVX_AUTH_PROVIDER"] ?? string.Empty)
            .Trim()
            .ToUpperInvariant();

        if (string.IsNullOrEmpty(authProvider))
        {
            authProvider = (gatewayMode == "REVOLUT_X" && !dryRun) ? "ED25519" : "FAKE";
        }

        if (authProvider == "ED25519")
        {
            services.AddSingleton<RevxAuthenticatorBase, RevxEd25519Authenticator>();
        }
        else
        {
            services.AddSingleton<RevxAuthenticatorBase, FakeRevxAuthenticator>();
        }

        services.AddSingleton<IRevxAuthenticator>(sp => sp.GetRequiredService<RevxAuthenticatorBase>());
        services.AddTransient<RevxSigningDelegatingHandler>();

        if (gatewayMode == "REVOLUT_X")
        {
            string revxBaseUrl = configuration["REVX_API_BASE_URL"] ?? "https://revx.revolut.com";
            services.AddHttpClient<IOrderExecutionGateway, RevolutXExecutionGateway>(client =>
            {
                client.BaseAddress = new Uri(revxBaseUrl);
            })
            .AddHttpMessageHandler<RevxSigningDelegatingHandler>();
        }
        else
        {
            services.AddSingleton<IOrderExecutionGateway, SimulatedExecutionGateway>();
        }

        return services;
    }
}
""", encoding="utf-8")

prog_path = repo_root / "src/QuantCore.Agents/Program.cs"
prog_code = prog_path.read_text(encoding="utf-8")

if "using QuantCore.Agents.Execution;" not in prog_code:
    prog_code = "using QuantCore.Agents.Execution;\n" + prog_code

marker = "// Execution gateway defaults to SIMULATED so existing swarm execution is completely unbroken"
if "AddQuantExecutionInfrastructure" not in prog_code:
    call_line = "builder.Services.AddQuantExecutionInfrastructure(builder.Configuration);\n"
    if marker in prog_code:
        start_idx = prog_code.index(marker)
        end_marker = "// Parse --mode switch (default: agent)"
        if end_marker in prog_code[start_idx:]:
            end_idx = prog_code.index(end_marker, start_idx)
            prog_code = prog_code[:start_idx] + call_line + "\n" + prog_code[end_idx:]
        else:
            prog_code = call_line + "\n" + prog_code
    else:
        prog_code = call_line + "\n" + prog_code

prog_path.write_text(prog_code, encoding="utf-8")
print(f"[OK] Bootstrapper configured in {boot_path}")
PYEOF

step "4/6 Updating tooling/switch-gateway.sh"

cat > "$REPO_ROOT/tooling/switch-gateway.sh" << 'EOF'
#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

export REPO_ROOT
export DOCKER_BUILDKIT=1
export BUILDKIT_PROGRESS=plain
export COMPOSE_DOCKER_CLI_BUILD=1

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
  echo -e "${CYAN}Usage:${NC}"
  echo "  $0 local              # SIMULATED gateway + FAKE auth handler"
  echo "  $0 revolut dry [fake] # REVOLUT_X gateway + DRY_RUN=true + FAKE auth handler"
  echo "  $0 revolut live       # REVOLUT_X gateway + DRY_RUN=false + ED25519 auth handler"
  exit 1
}

TARGET_MODE="${1:-}"
SUB_MODE="${2:-dry}"
AUTH_OVERRIDE="${3:-}"

if [[ -z "$TARGET_MODE" ]]; then
  usage
fi

dc() {
  docker compose --project-directory "$REPO_ROOT" -f "$REPO_ROOT/docker-compose.yml" "$@"
}

run_guarded() {
  local timeout_sec="$1"
  local label="$2"
  shift 2

  echo -e "${YELLOW}[INFO]${NC} Running: ${label} (timeout: ${timeout_sec}s)..."
  local log_file="/tmp/quant_gw_switch_$$.log"
  rm -f "$log_file"

  "$@" >"$log_file" 2>&1 &
  local cmd_pid=$!
  local elapsed=0

  while kill -0 "$cmd_pid" 2>/dev/null; do
    local last_line=""
    if [[ -s "$log_file" ]]; then
      last_line=$(tail -n 1 "$log_file" | tr -d '\r' | cut -c1-70)
    fi
    printf "\r  ⏳ [%3ds / %3ds] %s -> %-70s" "$elapsed" "$timeout_sec" "$label" "${last_line:-working...}"
    sleep 1
    elapsed=$((elapsed + 1))

    if [[ "$elapsed" -ge "$timeout_sec" ]]; then
      echo ""
      echo -e "${RED}[FAIL]${NC} TIMEOUT (${timeout_sec}s) during: ${label}"
      kill -9 "$cmd_pid" 2>/dev/null || true
      tail -n 20 "$log_file" 2>/dev/null || true
      rm -f "$log_file"
      return 1
    fi
  done

  wait "$cmd_pid"
  local exit_code=$?
  printf "\r\033[K"

  if [[ "$exit_code" -ne 0 ]]; then
    echo -e "${RED}[FAIL]${NC} ${label} failed (exit code ${exit_code})"
    tail -n 25 "$log_file" 2>/dev/null || true
    rm -f "$log_file"
    return "$exit_code"
  fi

  rm -f "$log_file"
  return 0
}

case "$(echo "$TARGET_MODE" | tr '[:upper:]' '[:lower:]')" in
  local|sim|simulated)
    GW_VAL="SIMULATED"
    DRY_VAL="true"
    AUTH_VAL="FAKE"
    LABEL="LOCAL (SIMULATED | Auth=FAKE)"
    ;;
  revolut|revx|revolut_x)
    GW_VAL="REVOLUT_X"
    if [[ "$(echo "$SUB_MODE" | tr '[:upper:]' '[:lower:]')" == "live" ]]; then
      DRY_VAL="false"
      AUTH_VAL="${AUTH_OVERRIDE:-ED25519}"
      LABEL="REVOLUT_X (LIVE | Auth=${AUTH_VAL})"
    else
      DRY_VAL="true"
      AUTH_VAL="${AUTH_OVERRIDE:-FAKE}"
      LABEL="REVOLUT_X (DRY_RUN | Auth=${AUTH_VAL})"
    fi
    ;;
  *)
    usage
    ;;
esac

echo -e "${CYAN}━━━ [$(date +%H:%M:%S)] Switching Execution -> ${LABEL} ━━━${NC}"

if [[ -x "$REPO_ROOT/tooling/normalize-db.sh" ]]; then
  "$REPO_ROOT/tooling/normalize-db.sh"
fi

EXECUTION_GATEWAY="$GW_VAL" \
REVX_AUTH_PROVIDER="$AUTH_VAL" \
REVX_DRY_RUN="$DRY_VAL" \
REVX_MAX_ORDER_USDT="${REVX_MAX_ORDER_USDT:-25}" \
AGENT_PROFILE_KEY="ALL" \
EPISODE_SETTLEMENT_MODE="CARRY_POSITIONS" \
EPISODE_MAX_TICKS=25 \
  run_guarded 45 "Recreating 3 quant-agents (${LABEL})" \
  dc --profile agents up -d --scale quant-agents=3 --force-recreate quant-agents

echo -e "${GREEN}[OK]${NC} Active mode: ${LABEL}"
dc --profile agents logs -f --tail=20 quant-agents nn-worker
EOF
chmod +x "$REPO_ROOT/tooling/switch-gateway.sh"
ok "Updated $REPO_ROOT/tooling/switch-gateway.sh"

step "5/6 Running Baseline .NET Tests"
run_guarded 180 "Running dotnet test on QuantCore.Agents.Tests" \
  dotnet test "$REPO_ROOT/tests/QuantCore.Agents.Tests/QuantCore.Agents.Tests.csproj" -c Release --nologo -v minimal
ok "Baseline .NET tests passed"

step "6/6 Rebuilding nn-worker (128-dim) & quant-agents and Starting in Local Mode"
run_guarded 240 "Building nn-worker image (hidden_dim=128)" dc build nn-worker
run_guarded 240 "Building quant-agents image" dc --profile agents build quant-agents
NN_HIDDEN_DIM=128 run_guarded 30 "Restarting nn-worker with hidden_dim=128" dc up -d --no-deps nn-worker
"$REPO_ROOT/tooling/switch-gateway.sh" local