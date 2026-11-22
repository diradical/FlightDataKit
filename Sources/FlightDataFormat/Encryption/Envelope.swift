// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import CryptoKit
import Foundation

/// Seals and opens the two parts of a report with HPKE, to the recipient's X25519 public key, bound to the
/// report's ID and the part. See <doc:Format> for the layout.
public enum Envelope {
    /// The two parts of a report that are sealed: its text, and the archive of its files.
    ///
    /// The raw value is the name the part has in the associated data, and in the report JSON for the text.
    public enum Part: String, Sendable {
        /// The report's text: a ``ReportText`` as JSON.
        case text = "sealed"
        /// The report's files: an archive made by ``Payload/pack(_:)``.
        case payload
    }

    /// The marker every envelope starts with.
    private static let magic = Data("FDR1".utf8)
    /// The HPKE `info`, which binds every envelope to this format.
    private static let info = Data("dev.flightdata.report.v1".utf8)
    private static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    /// The key ID's length in the header: the start of the SHA-256 of the raw public key.
    private static let keyIDLength = 8
    /// An X25519 encapsulated key.
    private static let encapsulatedKeyLength = 32
    /// ChaCha20-Poly1305's authentication tag.
    private static let tagLength = 16
    private static let headerLength = magic.count + keyIDLength + encapsulatedKeyLength
    /// What an envelope adds to what it seals: the header and the tag.
    static let overhead = headerLength + tagLength

    /// The largest envelope of each part, which is also what the server accepts.
    public static func maximumBytes(for part: Part) -> Int {
        switch part {
        case .text: 36_000
        case .payload: 10_000_000
        }
    }

    /// The key's ID as reports carry it: 16 lowercase hex digits.
    public static func keyID(for key: Curve25519.KeyAgreement.PublicKey) -> String {
        keyIDBytes(for: key).map { String(format: "%02x", $0) }.joined()
    }

    /// Seals one part of the report `reportID` to `key`.
    ///
    /// - Throws: ``EnvelopeError/tooLarge`` when the part is larger than its envelope may hold, and
    ///   ``EnvelopeError/invalidPublicKey`` for a key that can't be used for key agreement.
    public static func seal(_ plaintext: Data, to key: Curve25519.KeyAgreement.PublicKey,
                            reportID: UUID, part: Part) throws -> Data {
        guard plaintext.count <= maximumBytes(for: part) - overhead else {
            throw EnvelopeError.tooLarge
        }
        var sender: HPKE.Sender
        do {
            sender = try .init(recipientKey: key, ciphersuite: suite, info: info)
        } catch { throw EnvelopeError.invalidPublicKey }
        let ciphertext = try sender.seal(plaintext, authenticating: associatedData(reportID, part))
        return magic + keyIDBytes(for: key) + sender.encapsulatedKey + ciphertext
    }

    /// Opens a part sealed for the report `reportID`.
    ///
    /// - Throws: ``EnvelopeError/wrongKey`` when the envelope was sealed to another key, and
    ///   ``EnvelopeError/authenticationFailed`` when it was changed or belongs to another report or part.
    public static func open(_ envelope: Data, using key: Curve25519.KeyAgreement.PrivateKey,
                            reportID: UUID, part: Part) throws -> Data {
        guard envelope.count <= maximumBytes(for: part) else { throw EnvelopeError.tooLarge }
        guard envelope.count >= overhead, envelope.prefix(magic.count) == magic else {
            throw EnvelopeError.invalidEnvelope
        }
        let keyIDRange = magic.count..<(magic.count + keyIDLength)
        let encapsulatedRange = keyIDRange.upperBound..<headerLength
        let start = envelope.startIndex
        guard envelope[(start + keyIDRange.lowerBound)..<(start + keyIDRange.upperBound)]
                == keyIDBytes(for: key.publicKey) else {
            throw EnvelopeError.wrongKey
        }
        do {
            let encapsulated = envelope[(start + encapsulatedRange.lowerBound)..<(start + encapsulatedRange.upperBound)]
            var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: suite, info: info,
                                               encapsulatedKey: Data(encapsulated))
            return try recipient.open(Data(envelope.dropFirst(headerLength)),
                                      authenticating: associatedData(reportID, part))
        } catch { throw EnvelopeError.authenticationFailed }
    }

    private static func keyIDBytes(for key: Curve25519.KeyAgreement.PublicKey) -> Data {
        Data(SHA256.hash(data: key.rawRepresentation).prefix(keyIDLength))
    }

    /// The report's ID in lowercase, a slash and the part's name, as UTF-8.
    private static func associatedData(_ reportID: UUID, _ part: Part) -> Data {
        Data("\(reportID.uuidString.lowercased())/\(part.rawValue)".utf8)
    }
}
