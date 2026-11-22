// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import CryptoKit
import Foundation

/// The key text written before keys had a checksum: `fdpk1_` and the unpadded base64url of the 32 raw bytes. Keys
/// already kept in that form are still read; nothing writes it.
enum EarlierPublicKey {
    private static let prefix = "fdpk1_"
    private static let textLength = 49

    static func bytes(_ string: String) -> Data? {
        guard string.hasPrefix(prefix), string.utf8.count == textLength,
              let decoded = Envelope.fromBase64URL(String(string.dropFirst(prefix.count))), decoded.count == 32 else {
            return nil
        }
        return decoded
    }

    static func string(_ key: Curve25519.KeyAgreement.PublicKey) -> String {
        prefix + Envelope.base64URL(key.rawRepresentation)
    }
}
