import Foundation
import Security
import Testing
@testable import skyformac

struct VertexServiceAccountAuthenticatorTests {
    /// A real RSA key pair, generated fresh for this test (never persisted) — `SecKeyCopyExternalRepresentation`
    /// exports an RSA private key's own PKCS#1 `RSAPrivateKey` DER directly on Apple platforms, which is
    /// exactly the reference this test needs: does `pkcs1DER(fromPEM:)` recover the *same* bytes after
    /// they've been wrapped in a PKCS#8 `PrivateKeyInfo` envelope, the way Google's own service-account
    /// JSON always ships them.
    private func makeTestRSAKeyPair() throws -> (privateKey: SecKey, pkcs1DER: Data) {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw try #require(error?.takeRetainedValue())
        }
        guard let pkcs1 = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            throw try #require(error?.takeRetainedValue())
        }
        return (privateKey, pkcs1)
    }

    /// DER length-encoding, short or long form — needed to synthesize a realistic PKCS#8 wrapper
    /// around an arbitrary-sized PKCS#1 key (a 2048-bit key's `RSAPrivateKey` DER is long enough to
    /// need the long form, which is exactly the case worth exercising here).
    private func derLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var bytes: [UInt8] = []
        var remaining = length
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    /// Wraps a PKCS#1 `RSAPrivateKey` DER into a PKCS#8 `PrivateKeyInfo` — the exact ASN.1 shape
    /// `pkcs1DER(fromPEM:)` needs to unwrap: `SEQUENCE { version INTEGER ::= 0, algorithm
    /// AlgorithmIdentifier ::= rsaEncryption, privateKey OCTET STRING ::= <the PKCS#1 DER> }`. The
    /// `rsaEncryption` `AlgorithmIdentifier` (OID 1.2.840.113549.1.1.1 + a NULL parameter) is a
    /// fixed 15-byte DER sequence — real service-account keys use exactly this.
    private func wrapAsPKCS8(_ pkcs1: Data) -> Data {
        let algorithmIdentifier: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let version: [UInt8] = [0x02, 0x01, 0x00]
        let octetString = [0x04] + derLength(pkcs1.count) + Array(pkcs1)
        let body = Data(version) + Data(algorithmIdentifier) + Data(octetString)
        let outer = Data([0x30] + derLength(body.count)) + body
        return outer
    }

    private func pemEncode(_ der: Data) -> String {
        let base64 = der.base64EncodedString()
        var lines: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        return "-----BEGIN PRIVATE KEY-----\n\(lines.joined(separator: "\n"))\n-----END PRIVATE KEY-----"
    }

    @Test func pkcs1DERRecoversTheOriginalKeyFromAPKCS8WrappedPEM() throws {
        let (_, pkcs1) = try makeTestRSAKeyPair()
        let pem = pemEncode(wrapAsPKCS8(pkcs1))

        let recovered = try VertexServiceAccountAuthenticator.pkcs1DER(fromPEM: pem)
        #expect(recovered == pkcs1)
    }

    @Test func pkcs1DERPassesThroughAnAlreadyPKCS1PEMUnchanged() throws {
        let (_, pkcs1) = try makeTestRSAKeyPair()
        let base64 = pkcs1.base64EncodedString()
        let pem = "-----BEGIN RSA PRIVATE KEY-----\n\(base64)\n-----END RSA PRIVATE KEY-----"

        let recovered = try VertexServiceAccountAuthenticator.pkcs1DER(fromPEM: pem)
        #expect(recovered == pkcs1)
    }

    @Test func pkcs1DERThrowsForGarbagePEM() {
        #expect(throws: VertexServiceAccountAuthenticator.AuthError.self) {
            _ = try VertexServiceAccountAuthenticator.pkcs1DER(fromPEM: "-----BEGIN PRIVATE KEY-----\nnot valid base64!!!\n-----END PRIVATE KEY-----")
        }
    }

    /// End-to-end: a JWT actually signed with the PKCS#8-wrapped PEM (the real code path
    /// `VertexServiceAccountAuthenticator` uses) must verify against the original key pair's own
    /// public key — RSA PKCS#1v1.5 signatures are deterministic, but this test doesn't even lean on
    /// that; it just confirms the signature `SecKeyCreateWithData` + `SecKeyCreateSignature`
    /// produces from the recovered PKCS#1 DER is one the original key pair's public key accepts.
    @Test func signingWithAPKCS8WrappedKeyProducesASignatureTheOriginalPublicKeyVerifies() throws {
        let (privateKey, pkcs1) = try makeTestRSAKeyPair()
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            Issue.record("Couldn't derive the public key")
            return
        }
        let pem = pemEncode(wrapAsPKCS8(pkcs1))
        let recoveredDER = try VertexServiceAccountAuthenticator.pkcs1DER(fromPEM: pem)

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        guard let recoveredPrivateKey = SecKeyCreateWithData(recoveredDER as CFData, attributes as CFDictionary, &error) else {
            throw try #require(error?.takeRetainedValue())
        }
        let message = Data("test.signing.input".utf8)
        guard let signature = SecKeyCreateSignature(recoveredPrivateKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, &error) as Data? else {
            throw try #require(error?.takeRetainedValue())
        }
        let verified = SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, &error)
        #expect(verified)
    }
}
