// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import CryptoKit
import Foundation

extension Envelope {
    /// What a public key's text starts with.
    private static let keyPrefix = "fdpk2_"
    /// The bytes after the prefix: the raw key, then its checksum.
    private static let rawKeyLength = 32
    private static let checksumLength = 4
    /// The prefix and the unpadded base64url of 36 bytes.
    private static let keyTextLength = 54

    /// The key as text: `fdpk2_` and the unpadded base64url of the 32-byte key followed by a 4-byte checksum, so
    /// that a mistyped key is refused rather than silently sealing to a key nobody holds.
    public static func publicKeyString(_ key: Curve25519.KeyAgreement.PublicKey) -> String {
        keyPrefix + base64URL(key.rawRepresentation + checksum(key.rawRepresentation))
    }

    /// Reads a key written by ``publicKeyString(_:)``.
    ///
    /// - Throws: ``EnvelopeError/invalidPublicKey`` for anything else: another prefix, padding, whitespace, a
    ///   wrong length or checksum, or a spelling that isn't the canonical one.
    public static func publicKey(from string: String) throws -> Curve25519.KeyAgreement.PublicKey {
        let raw: Data
        let canonical: (Curve25519.KeyAgreement.PublicKey) -> String
        if let current = currentKeyBytes(string) {
            raw = current
            canonical = publicKeyString
        } else if let earlier = EarlierPublicKey.bytes(string) {
            raw = earlier
            canonical = EarlierPublicKey.string
        } else {
            throw EnvelopeError.invalidPublicKey
        }
        let key: Curve25519.KeyAgreement.PublicKey
        do { key = try .init(rawRepresentation: raw) } catch { throw EnvelopeError.invalidPublicKey }
        guard canonical(key) == string else { throw EnvelopeError.invalidPublicKey }
        return key
    }

    private static func currentKeyBytes(_ string: String) -> Data? {
        guard string.hasPrefix(keyPrefix), string.utf8.count == keyTextLength,
              let decoded = fromBase64URL(String(string.dropFirst(keyPrefix.count))),
              decoded.count == rawKeyLength + checksumLength,
              checksum(decoded.prefix(rawKeyLength)) == decoded.suffix(checksumLength) else { return nil }
        return Data(decoded.prefix(rawKeyLength))
    }

    /// The first four bytes of SHA-256 of `fdpk2` and the raw key.
    private static func checksum(_ raw: Data) -> Data {
        Data(SHA256.hash(data: Data("fdpk2".utf8) + raw).prefix(checksumLength))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Unpadded base64url; nil for any other character.
    static func fromBase64URL(_ string: String) -> Data? {
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
        guard string.utf8.allSatisfy(alphabet.contains) else { return nil }
        let standard = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: standard + String(repeating: "=", count: (4 - standard.count % 4) % 4))
    }
}
