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

        // Revolut X signs: timestamp + METHOD + /api/... + query_string_WITHOUT_question_mark + body
        string raw = string.IsNullOrWhiteSpace(requestPathAndQuery) ? "/" : requestPathAndQuery.Trim();
        string normalizedPath;
        string normalizedQuery = string.Empty;

        int qIdx = raw.IndexOf('?');
        if (qIdx >= 0)
        {
            normalizedPath = raw[..qIdx];
            normalizedQuery = raw[(qIdx + 1)..];
        }
        else
        {
            normalizedPath = raw;
        }

        if (!normalizedPath.StartsWith('/'))
        {
            normalizedPath = "/" + normalizedPath;
        }

        string payload = $"{timestampMs.ToString(CultureInfo.InvariantCulture)}{normalizedMethod}{normalizedPath}{normalizedQuery}{minifiedBody ?? string.Empty}";
        return SignPayload(normalizedMethod, normalizedPath, payload, timestampMs);
    }

    protected abstract RevxAuthHeaders SignPayload(
        string normalizedMethod,
        string normalizedPath,
        string canonicalPayload,
        long timestampMs);
}
