// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Compression
import Foundation

/// RFC 1952 gzip around the raw deflate stream Apple's Compression framework produces.
/// The header carries no time or name, so the same input always packs to the same bytes.
enum Gzip {
    private static let magic: [UInt8] = [0x1f, 0x8b]
    private static let deflate: UInt8 = 8
    /// The header's flag bits.
    private enum Flag {
        static let headerCRC: UInt8 = 0x02
        static let extra: UInt8 = 0x04
        static let name: UInt8 = 0x08
        static let comment: UInt8 = 0x10
        static let reserved: UInt8 = 0xe0
    }
    /// Magic, method, flags, a zero time, no extra flags, and the operating system as unknown.
    private static let header: [UInt8] = magic + [deflate, 0, 0, 0, 0, 0, 0, 0xff]
    /// The CRC-32 and the length of the plain data, each four bytes, little-endian.
    private static let trailerLength = 8
    private static let chunk = 64 * 1_024

    static func compress(_ data: Data) throws -> Data {
        var out = Data(header)
        out.append(try transform(data, operation: COMPRESSION_STREAM_ENCODE, maximumBytes: Int.max))
        out.append(contentsOf: littleEndian(CRC32.checksum(data)))
        out.append(contentsOf: littleEndian(UInt32(truncatingIfNeeded: data.count)))
        return out
    }

    /// Reads one gzip member. Fails when the output would pass `maximumBytes`, so a small archive can't expand
    /// without limit.
    static func decompress(_ data: Data, maximumBytes: Int) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= header.count + trailerLength, bytes.starts(with: magic + [deflate]) else {
            throw PayloadError.invalidArchive
        }
        let flags = bytes[3]
        guard flags & Flag.reserved == 0 else { throw PayloadError.invalidArchive }
        let trailer = bytes.count - trailerLength
        var offset = header.count
        if flags & Flag.extra != 0 {
            guard offset + 2 <= trailer else { throw PayloadError.invalidArchive }
            offset += 2 + (Int(bytes[offset]) | Int(bytes[offset + 1]) << 8)
        }
        for flag in [Flag.name, Flag.comment] where flags & flag != 0 {
            guard offset < trailer, let end = bytes[offset..<trailer].firstIndex(of: 0) else {
                throw PayloadError.invalidArchive
            }
            offset = end + 1
        }
        if flags & Flag.headerCRC != 0 {
            guard offset + 2 <= trailer,
                  UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                    == UInt16(truncatingIfNeeded: CRC32.checksum(bytes[..<offset])) else {
                throw PayloadError.invalidArchive
            }
            offset += 2
        }
        guard offset <= trailer else { throw PayloadError.invalidArchive }
        let plain = try transform(Data(bytes[offset..<trailer]), operation: COMPRESSION_STREAM_DECODE,
                                  maximumBytes: maximumBytes)
        guard littleEndian(bytes, at: trailer) == CRC32.checksum(plain),
              littleEndian(bytes, at: trailer + 4) == UInt32(truncatingIfNeeded: plain.count) else {
            throw PayloadError.invalidArchive
        }
        return plain
    }

    private static func transform(_ input: Data, operation: compression_stream_operation,
                                  maximumBytes: Int) throws -> Data {
        let placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { placeholder.deallocate() }
        var stream = compression_stream(dst_ptr: placeholder, dst_size: 0, src_ptr: UnsafePointer(placeholder),
                                        src_size: 0, state: nil)
        guard compression_stream_init(&stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw PayloadError.invalidArchive
        }
        defer { compression_stream_destroy(&stream) }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var output = Data()
        return try input.withUnsafeBytes { raw in
            stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(placeholder)
            stream.src_size = raw.count
            let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
            while true {
                stream.dst_ptr = buffer
                stream.dst_size = chunk
                let status = compression_stream_process(&stream, flags)
                guard status != COMPRESSION_STATUS_ERROR else { throw PayloadError.invalidArchive }
                output.append(buffer, count: chunk - stream.dst_size)
                guard output.count <= maximumBytes else { throw PayloadError.tooLarge }
                if status == COMPRESSION_STATUS_END {
                    guard stream.src_size == 0 else { throw PayloadError.invalidArchive }
                    return output
                }
                // More input is pending, or the decoder needs more than the stream holds (truncated).
                guard stream.src_size > 0 || stream.dst_size == 0 else { throw PayloadError.invalidArchive }
            }
        }
    }

    private static func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    private static func littleEndian(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }
}
