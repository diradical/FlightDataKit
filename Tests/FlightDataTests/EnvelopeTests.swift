// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import CryptoKit
import Foundation
import Testing
@testable import FlightData
@testable import FlightDataFeedback
@testable import FlightDataFormat

private struct EnvelopeFixture: Decodable {
    struct Vector: Decodable {
        let part: String
        let plaintext_base64: String
        let envelope_base64: String
    }
    let report_id: UUID
    let private_key_base64: String
    let public_key: String
    let earlier_public_key: String
    let key_id: String
    let vectors: [Vector]

    static func load() throws -> Self {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Resources/envelopes.json")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }
}

@Test func fixedEnvelopesOpenWithDocumentedKeyAndContext() throws {
    let fixture = try EnvelopeFixture.load()
    let raw = try #require(Data(base64Encoded: fixture.private_key_base64))
    let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
    #expect(Envelope.publicKeyString(key.publicKey) == fixture.public_key)
    #expect(try Envelope.publicKey(from: fixture.public_key).rawRepresentation == key.publicKey.rawRepresentation)
    let earlier = try Envelope.publicKey(from: fixture.earlier_public_key)
    #expect(earlier.rawRepresentation == key.publicKey.rawRepresentation, "a key kept in the earlier form still reads")
    #expect(Envelope.keyID(for: key.publicKey) == fixture.key_id)
    for vector in fixture.vectors {
        let part = try #require(Envelope.Part(rawValue: vector.part))
        let bytes = try #require(Data(base64Encoded: vector.envelope_base64))
        let expected = try #require(Data(base64Encoded: vector.plaintext_base64))
        #expect(try Envelope.open(bytes, using: key, reportID: fixture.report_id, part: part) == expected)
    }
    // The text vector was written before values had types, and still reads.
    let text = try #require(fixture.vectors.first { $0.part == "sealed" })
    let opened = try ReportText.decode(try #require(Data(base64Encoded: text.plaintext_base64)))
    #expect(opened.fields == ["answered by": "Fixture"])
}

/// RFC 9180, appendix A.2.1: DHKEM(X25519, HKDF-SHA256), HKDF-SHA256 and ChaCha20-Poly1305 in base mode, the suite
/// envelopes use. CryptoKit's HPKE must open the RFC's first two ciphertexts with the RFC's keys.
@Test func theHPKESuiteMatchesTheRFC9180Vectors() throws {
    func bytes(_ hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).map { offset in
            UInt8(hex.dropFirst(offset).prefix(2), radix: 16)!
        })
    }
    let recipientKey = try Curve25519.KeyAgreement.PrivateKey(
        rawRepresentation: bytes("8057991eef8f1f1af18f4a9491d16a1ce333f695d4db8e38da75975c4478e0fb"))
    #expect(recipientKey.publicKey.rawRepresentation
            == bytes("4310ee97d88cc1f088a5576c77ab0cf5c3ac797f3d95139c6c84b5429c59662a"))
    var recipient = try HPKE.Recipient(
        privateKey: recipientKey, ciphersuite: .Curve25519_SHA256_ChachaPoly,
        info: bytes("4f6465206f6e2061204772656369616e2055726e"),
        encapsulatedKey: bytes("1afa08d3dec047a643885163f1180476fa7ddb54c6a8029ea33f95796bf2ac4a"))
    let plaintext = bytes("4265617574792069732074727574682c20747275746820626561757479")
    #expect(try recipient.open(
        bytes("1c5250d8034ec2b784ba2cfd69dbdb8af406cfe3ff938e131f0def8c8b60b4db21993c62ce81883d2dd1b51a28"),
        authenticating: bytes("436f756e742d30")) == plaintext)
    #expect(try recipient.open(
        bytes("6b53c051e4199c518de79594e1c4ab18b96f081549d45ce015be002090bb119e85285337cc95ba5f59992dc98c"),
        authenticating: bytes("436f756e742d31")) == plaintext)
}

@Test func publicKeysRequireCanonicalEncoding() throws {
    let key = Curve25519.KeyAgreement.PrivateKey().publicKey
    let encoded = Envelope.publicKeyString(key)
    #expect(try Envelope.publicKey(from: encoded).rawRepresentation == key.rawRepresentation)
    #expect(encoded.hasPrefix("fdpk2_") && encoded.utf8.count == 54)
    var typo = Array(encoded)
    typo[20] = typo[20] == "A" ? "B" : "A"
    for invalid in ["", "fdpk3_" + String(encoded.dropFirst(6)), encoded + "=", encoded + "\n", String(typo),
                    "fdpk1_" + String(repeating: "!", count: 43)] {
        #expect(throws: EnvelopeError.invalidPublicKey) { try Envelope.publicKey(from: invalid) }
    }
    let canonical = Envelope.publicKeyString(try .init(rawRepresentation: Data(repeating: 0, count: 32)))
    let noncanonical = String(canonical.dropLast()) + "B"
    #expect(throws: EnvelopeError.invalidPublicKey) { try Envelope.publicKey(from: noncanonical) }
}

@Test func sealingUsesIndependentRandomnessAndOpensBinaryContent() throws {
    let key = Curve25519.KeyAgreement.PrivateKey()
    let reportID = UUID()
    let plaintext = Data([0, 128, 255]) + Data("Synthetic feedback".utf8)
    for part in [Envelope.Part.text, .payload] {
        let first = try Envelope.seal(plaintext, to: key.publicKey, reportID: reportID, part: part)
        let second = try Envelope.seal(plaintext, to: key.publicKey, reportID: reportID, part: part)
        #expect(first != second)
        #expect(first.count == plaintext.count + 60)
        #expect(try Envelope.open(first, using: key, reportID: reportID, part: part) == plaintext)
        #expect(first.range(of: plaintext) == nil)
    }
}

@Test func everyEnvelopeByteIsProtectedAgainstModification() throws {
    let key = Curve25519.KeyAgreement.PrivateKey()
    let reportID = UUID()
    let envelope = try Envelope.seal(Data("Synthetic tamper test".utf8), to: key.publicKey,
                                     reportID: reportID, part: .text)
    for index in envelope.indices {
        var modified = envelope
        modified[index] ^= 1
        #expect(throws: EnvelopeError.self) {
            try Envelope.open(modified, using: key, reportID: reportID, part: .text)
        }
    }
}

@Test func reportIdentityPartAndPrivateKeyMustMatch() throws {
    let key = Curve25519.KeyAgreement.PrivateKey()
    let other = Curve25519.KeyAgreement.PrivateKey()
    let reportID = UUID()
    let envelope = try Envelope.seal(Data("Synthetic context".utf8), to: key.publicKey,
                                     reportID: reportID, part: .text)
    #expect(throws: EnvelopeError.authenticationFailed) {
        try Envelope.open(envelope, using: key, reportID: UUID(), part: .text)
    }
    #expect(throws: EnvelopeError.authenticationFailed) {
        try Envelope.open(envelope, using: key, reportID: reportID, part: .payload)
    }
    #expect(throws: EnvelopeError.wrongKey) {
        try Envelope.open(envelope, using: other, reportID: reportID, part: .text)
    }
    var forgedHeader = envelope
    let otherID = Data(SHA256.hash(data: other.publicKey.rawRepresentation)).prefix(8)
    forgedHeader.replaceSubrange(4..<12, with: otherID)
    #expect(throws: EnvelopeError.authenticationFailed) {
        try Envelope.open(forgedHeader, using: other, reportID: reportID, part: .text)
    }
}

@Test func truncatedEnvelopesAndTrailingBytesAreRejected() throws {
    let key = Curve25519.KeyAgreement.PrivateKey()
    let reportID = UUID()
    let envelope = try Envelope.seal(Data("Synthetic bounds".utf8), to: key.publicKey,
                                     reportID: reportID, part: .text)
    for size in 0..<envelope.count {
        #expect(throws: EnvelopeError.self) {
            try Envelope.open(Data(envelope.prefix(size)), using: key, reportID: reportID, part: .text)
        }
    }
    #expect(throws: EnvelopeError.authenticationFailed) {
        try Envelope.open(envelope + Data([0]), using: key, reportID: reportID, part: .text)
    }
    let padded = Data([0, 1]) + envelope
    #expect(try Envelope.open(padded.dropFirst(2), using: key, reportID: reportID, part: .text)
            == Data("Synthetic bounds".utf8))
}

@Test func envelopeLimitsIncludeHeaderTagAndBase64Expansion() throws {
    let key = Curve25519.KeyAgreement.PrivateKey()
    let reportID = UUID()
    let maximum = Envelope.maximumBytes(for: .text)
    let envelope = try Envelope.seal(Data(repeating: 42, count: maximum - 60), to: key.publicKey,
                                     reportID: reportID, part: .text)
    #expect(envelope.count == maximum)
    #expect(envelope.base64EncodedString().utf8.count == 48_000)
    #expect(try Envelope.open(envelope, using: key, reportID: reportID, part: .text).count == maximum - 60)
    #expect(throws: EnvelopeError.tooLarge) {
        try Envelope.seal(Data(repeating: 42, count: maximum - 59), to: key.publicKey,
                          reportID: reportID, part: .text)
    }
    #expect(throws: EnvelopeError.tooLarge) {
        try Envelope.open(envelope + Data([0]), using: key, reportID: reportID, part: .text)
    }
    #expect(throws: EnvelopeError.tooLarge) {
        try Envelope.open(Data(repeating: 0, count: 10_000_001), using: key, reportID: reportID, part: .payload)
    }
    #expect(throws: EnvelopeError.tooLarge) {
        try Envelope.seal(Data(repeating: 0, count: 10_000_000 - 59), to: key.publicKey,
                          reportID: reportID, part: .payload)
    }
}

@Test func unusableRecipientKeysFailAndEmptyMessagesAreSupported() throws {
    let zero = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(repeating: 0, count: 32))
    #expect(throws: EnvelopeError.invalidPublicKey) {
        try Envelope.seal(Data(), to: zero, reportID: UUID(), part: .text)
    }
    let key = Curve25519.KeyAgreement.PrivateKey()
    let reportID = UUID()
    let bytes = try Envelope.seal(Data(), to: key.publicKey, reportID: reportID, part: .text)
    #expect(bytes.count == 60)
    #expect(try Envelope.open(bytes, using: key, reportID: reportID, part: .text).isEmpty)
}

@Test func aMistypedPublicKeyIsRefusedByItsChecksum() throws {
    let encoded = Array(Envelope.publicKeyString(Curve25519.KeyAgreement.PrivateKey().publicKey))
    for index in 6..<encoded.count {
        var typo = encoded
        typo[index] = typo[index] == "x" ? "y" : "x"
        #expect(throws: EnvelopeError.invalidPublicKey) { try Envelope.publicKey(from: String(typo)) }
    }
}

@Test func privateKeysRoundTripThroughPEMThatOpenSSLReads() throws {
    let key = Curve25519.KeyAgreement.PrivateKey()
    let pem = PrivateKeyPEM.encode(key)
    #expect(pem.hasPrefix("-----BEGIN PRIVATE KEY-----\n"))
    #expect(try PrivateKeyPEM.decode(pem).rawRepresentation == key.rawRepresentation)
    // PKCS#8 X25519 header followed by a synthetic scalar containing the bytes 0 through 31.
    let scalar = Data(UInt8(0)..<UInt8(32))
    let header = Data([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06,
                       0x03, 0x2b, 0x65, 0x6e, 0x04, 0x22, 0x04, 0x20])
    let sample = ["-----BEGIN PRIVATE KEY-----", (header + scalar).base64EncodedString(),
                  "-----END PRIVATE KEY-----"].joined(separator: "\n")
    #expect(try PrivateKeyPEM.decode(sample).rawRepresentation == scalar)
    for bad in ["", "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----",
                pem.replacingOccurrences(of: "PRIVATE", with: "PUBLIC")] {
        #expect(throws: EnvelopeError.invalidPrivateKey) { try PrivateKeyPEM.decode(bad) }
    }
}
