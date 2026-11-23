using System.Globalization;

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
