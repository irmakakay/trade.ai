using System.Globalization;
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
                    $"{{\"status\":\"DRY_RUN\",\"auth\":\"{_authenticator.AuthenticatorName}\",\"timestamp_ms\":{auth.TimestampMs}}}",
                    Encoding.UTF8,
                    new MediaTypeHeaderValue("application/json"))
            };
        }

        return await base.SendAsync(request, ct);
    }
}
