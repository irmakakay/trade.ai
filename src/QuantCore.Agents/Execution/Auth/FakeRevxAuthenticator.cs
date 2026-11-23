using System.Security.Cryptography;
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
