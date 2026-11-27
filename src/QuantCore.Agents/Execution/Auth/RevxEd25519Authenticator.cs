using System.Text;
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
        _apiKey = (config["REVX_API_KEY"] ?? string.Empty).Trim().Trim('"');
        string pemOrPath = (config["REVX_PRIVATE_KEY_PEM"] ?? string.Empty).Trim().Trim('"');

        if (string.IsNullOrWhiteSpace(pemOrPath))
            return;

        try
        {
            string pemText = File.Exists(pemOrPath)
                ? File.ReadAllText(pemOrPath)
                : pemOrPath.Replace("\\r\\n", "\n").Replace("\\n", "\n").Replace("\\r", string.Empty);

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
