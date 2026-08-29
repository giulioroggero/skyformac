import Foundation
import Security

/// Mints short-lived OAuth2 access tokens for Vertex AI from a downloaded GCP service-account JSON
/// key — Vertex has no simple `?key=API_KEY` auth the way the plain Gemini API does; every request
/// needs an `Authorization: Bearer <token>` header, and getting one from just a service-account key
/// (no `gcloud` CLI, no Google Cloud SDK — this is a plain Swift/AppKit app) means doing the
/// [JWT Bearer Token flow](https://developers.google.com/identity/protocols/oauth2/service-account)
/// by hand: build a signed JWT asserting this app *is* the service account, then exchange it at
/// Google's token endpoint for a real access token.
enum VertexServiceAccountAuthenticator {
    enum AuthError: Error {
        /// The stored text isn't valid JSON, or is missing `client_email`/`private_key`.
        case malformedServiceAccountJSON
        /// `private_key`'s PEM couldn't be parsed into an RSA key Security recognizes — most
        /// likely a key pasted/exported incorrectly (missing the PEM header/footer, or truncated).
        case invalidPrivateKey
        /// Google's own token endpoint rejected the JWT — `message`, when present, is its own
        /// `error_description`, e.g. "Invalid JWT Signature" for a key/JSON mismatch.
        case tokenExchangeFailed(message: String?)
    }

    private struct ServiceAccountCredentials: Decodable {
        var client_email: String
        var private_key: String
        var token_uri: String?
    }

    private struct TokenResponse: Decodable {
        var access_token: String
        var expires_in: Int?
    }

    /// A single signed-and-exchanged access token is good for up to an hour — cached here (keyed
    /// by which credentials produced it, so switching service accounts in Settings mid-session
    /// can't hand back a stale token minted for a *different* one) so a burst of chat/enhance
    /// requests doesn't re-sign a fresh JWT and hit Google's token endpoint on every single one.
    private actor TokenCache {
        static let shared = TokenCache()
        private var cached: (credentialsHash: Int, token: String, expiresAt: Date)?

        func accessToken(serviceAccountJSON: String) async throws -> String {
            let hash = serviceAccountJSON.hashValue
            if let cached, cached.credentialsHash == hash, cached.expiresAt > Date().addingTimeInterval(60) {
                return cached.token
            }
            let (token, expiresIn) = try await VertexServiceAccountAuthenticator.exchangeForAccessToken(serviceAccountJSON: serviceAccountJSON)
            cached = (hash, token, Date().addingTimeInterval(TimeInterval(expiresIn)))
            return token
        }
    }

    /// A valid Bearer token for `serviceAccountJSON` — from cache when still fresh, otherwise a
    /// freshly signed-and-exchanged one.
    static func accessToken(serviceAccountJSON: String) async throws -> String {
        try await TokenCache.shared.accessToken(serviceAccountJSON: serviceAccountJSON)
    }

    private static func exchangeForAccessToken(serviceAccountJSON: String) async throws -> (token: String, expiresIn: Int) {
        guard let data = serviceAccountJSON.data(using: .utf8),
              let credentials = try? JSONDecoder().decode(ServiceAccountCredentials.self, from: data)
        else { throw AuthError.malformedServiceAccountJSON }

        let tokenURI = (credentials.token_uri?.isEmpty == false ? credentials.token_uri! : "https://oauth2.googleapis.com/token")
        let now = Int(Date().timeIntervalSince1970)
        let headerSegment = try base64URLEncode(JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"]))
        let claimsSegment = try base64URLEncode(JSONSerialization.data(withJSONObject: [
            "iss": credentials.client_email,
            "scope": "https://www.googleapis.com/auth/cloud-platform",
            "aud": tokenURI,
            "iat": now,
            "exp": now + 3600,
        ]))
        let signingInput = "\(headerSegment).\(claimsSegment)"
        let signature = try sign(signingInput, withPEMPrivateKey: credentials.private_key)
        let jwt = "\(signingInput).\(base64URLEncode(signature))"

        var request = URLRequest(url: URL(string: tokenURI)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        let encodedJWT = jwt.addingPercentEncoding(withAllowedCharacters: allowed) ?? jwt
        request.httpBody = Data("grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=\(encodedJWT)".utf8)

        let (data2, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let envelope = try? JSONSerialization.jsonObject(with: data2) as? [String: Any]
            let message = (envelope?["error_description"] as? String) ?? (envelope?["error"] as? String)
            throw AuthError.tokenExchangeFailed(message: message)
        }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data2) else {
            throw AuthError.tokenExchangeFailed(message: nil)
        }
        return (decoded.access_token, decoded.expires_in ?? 3600)
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sign(_ input: String, withPEMPrivateKey pem: String) throws -> Data {
        let der = try pkcs1DER(fromPEM: pem)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            throw AuthError.invalidPrivateKey
        }
        guard let signature = SecKeyCreateSignature(
            secKey, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, &error
        ) as Data? else {
            throw AuthError.invalidPrivateKey
        }
        return signature
    }

    /// Google's service-account JSON ships its RSA private key as PKCS#8 PEM
    /// (`-----BEGIN PRIVATE KEY-----`), but `SecKeyCreateWithData` with `kSecAttrKeyTypeRSA` only
    /// accepts a bare PKCS#1 `RSAPrivateKey` DER — this strips PKCS#8's outer `PrivateKeyInfo`
    /// wrapper to recover it. A key already in PKCS#1 form (`-----BEGIN RSA PRIVATE KEY-----`,
    /// less common but valid) is passed through unchanged.
    static func pkcs1DER(fromPEM pem: String) throws -> Data {
        let isAlreadyPKCS1 = pem.contains("BEGIN RSA PRIVATE KEY")
        let stripped = pem
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let der = Data(base64Encoded: stripped) else { throw AuthError.invalidPrivateKey }
        if isAlreadyPKCS1 { return der }
        guard let pkcs1 = extractPKCS1(fromPKCS8: der) else { throw AuthError.invalidPrivateKey }
        return pkcs1
    }

    /// Minimal ASN.1 DER walk — just enough to parse `PrivateKeyInfo ::= SEQUENCE { version
    /// INTEGER, algorithm AlgorithmIdentifier, privateKey OCTET STRING }` far enough to reach that
    /// final OCTET STRING, whose *contents* are exactly the PKCS#1 `RSAPrivateKey` DER Security
    /// wants. Reads only SEQUENCE/INTEGER/OCTET STRING tag+length headers (with full multi-byte
    /// DER length support, since a 2048/3072/4096-bit key's `AlgorithmIdentifier` and `version`
    /// fields shift the overall length just enough to sometimes need one) — not a general-purpose
    /// ASN.1 parser.
    private static func extractPKCS1(fromPKCS8 der: Data) -> Data? {
        var index = der.startIndex

        func readTagLength() -> (tag: UInt8, length: Int)? {
            guard index < der.endIndex else { return nil }
            let tag = der[index]
            index = der.index(after: index)
            guard index < der.endIndex else { return nil }
            let first = der[index]
            index = der.index(after: index)
            let length: Int
            if first & 0x80 == 0 {
                length = Int(first)
            } else {
                let byteCount = Int(first & 0x7F)
                guard byteCount > 0, byteCount <= 4,
                      let after = der.index(index, offsetBy: byteCount, limitedBy: der.endIndex)
                else { return nil }
                var value = 0
                for offset in 0..<byteCount { value = (value << 8) | Int(der[der.index(index, offsetBy: offset)]) }
                length = value
                index = after
            }
            return (tag, length)
        }

        // Outer SEQUENCE (PrivateKeyInfo) — its own length isn't needed, just its presence.
        guard readTagLength()?.tag == 0x30 else { return nil }
        // version INTEGER — skip its content bytes.
        guard let version = readTagLength(), version.tag == 0x02,
              let afterVersion = der.index(index, offsetBy: version.length, limitedBy: der.endIndex)
        else { return nil }
        index = afterVersion
        // algorithm AlgorithmIdentifier (a SEQUENCE) — skip its entire content.
        guard let algorithm = readTagLength(), algorithm.tag == 0x30,
              let afterAlgorithm = der.index(index, offsetBy: algorithm.length, limitedBy: der.endIndex)
        else { return nil }
        index = afterAlgorithm
        // privateKey OCTET STRING — its content *is* the PKCS#1 key.
        guard let octetString = readTagLength(), octetString.tag == 0x04,
              let end = der.index(index, offsetBy: octetString.length, limitedBy: der.endIndex)
        else { return nil }
        return der.subdata(in: index..<end)
    }
}
