// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation

/// Why a part couldn't be sealed or opened.
public enum EnvelopeError: Error, Equatable, Sendable, LocalizedError {
    /// The public key isn't one ``Envelope/publicKey(from:)`` reads, or it can't be used for key agreement.
    case invalidPublicKey
    /// The text isn't an X25519 private key in PKCS#8 PEM.
    case invalidPrivateKey
    /// The bytes aren't an envelope: too short, or without the marker.
    case invalidEnvelope
    /// The part is larger than its envelope may be.
    case tooLarge
    /// The envelope was sealed to another key.
    case wrongKey
    /// The envelope was changed, or belongs to another report or part.
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPublicKey: "The encryption public key is invalid or mistyped."
        case .invalidPrivateKey: "The private key is not an X25519 key in PEM form."
        case .invalidEnvelope: "The encrypted report envelope is invalid."
        case .tooLarge: "The encrypted report exceeds its size limit."
        case .wrongKey: "This envelope needs a different encryption key."
        case .authenticationFailed: "The encrypted report could not be authenticated."
        }
    }
}
