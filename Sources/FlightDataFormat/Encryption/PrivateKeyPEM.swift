// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import CryptoKit
import Foundation

/// A private key as PKCS#8 PEM (`-----BEGIN PRIVATE KEY-----`), the form OpenSSL reads and writes for X25519
/// (`openssl genpkey -algorithm X25519`). For moving a key between tools.
public enum PrivateKeyPEM {
    /// The DER that comes before the 32 key bytes: PKCS#8 version 0, algorithm X25519 (1.3.101.110), and the key
    /// as an octet string.
    private static let prefix = Data([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06,
                                      0x03, 0x2b, 0x65, 0x6e, 0x04, 0x22, 0x04, 0x20])
    private static let begin = "-----BEGIN PRIVATE KEY-----"
    private static let end = "-----END PRIVATE KEY-----"

    /// The key as PEM text.
    public static func encode(_ key: Curve25519.KeyAgreement.PrivateKey) -> String {
        "\(begin)\n\((prefix + key.rawRepresentation).base64EncodedString())\n\(end)\n"
    }

    /// Reads PEM text. Throws ``EnvelopeError/invalidPrivateKey`` for anything else.
    public static func decode(_ pem: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(begin), trimmed.hasSuffix(end) else { throw EnvelopeError.invalidPrivateKey }
        let body = trimmed.dropFirst(begin.count).dropLast(end.count).filter { !$0.isWhitespace }
        guard let der = Data(base64Encoded: String(body)), der.count == prefix.count + 32,
              der.prefix(prefix.count) == prefix,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: der.suffix(32)) else {
            throw EnvelopeError.invalidPrivateKey
        }
        return key
    }
}
