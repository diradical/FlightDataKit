// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation

/// The CRC-32 gzip uses (ISO 3309, reflected, polynomial 0xedb88320).
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { value, _ in value & 1 == 1 ? 0xedb88320 ^ (value >> 1) : value >> 1 }
    }

    static func checksum<Bytes: Sequence<UInt8>>(_ bytes: Bytes) -> UInt32 {
        ~bytes.reduce(UInt32.max) { crc, byte in table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
    }
}
