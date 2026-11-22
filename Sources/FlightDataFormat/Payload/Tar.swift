// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation

/// The small slice of POSIX ustar the payload needs: regular files with flat names of at most 100 bytes.
enum Tar {
    struct Entry: Equatable {
        let name: String
        let data: Data
    }

    static let block = 512

    /// Where each field of a ustar header is, and how long it is.
    enum Field {
        static let name = 0..<100
        static let mode = 100..<108
        static let owner = 108..<116
        static let group = 116..<124
        static let size = 124..<136
        static let modified = 136..<148
        static let checksum = 148..<156
        static let type = 156
        static let magic = 257..<263
        static let version = 263..<265
        /// The link name, owner names, device numbers and name prefix, which these archives leave empty.
        static let unused = 345..<500
    }

    private static let regularFile = UInt8(ascii: "0")

    static func write(_ entries: [Entry]) throws -> Data {
        var out = Data()
        for entry in entries {
            out.append(try header(name: entry.name, size: entry.data.count))
            out.append(entry.data)
            out.append(Data(count: padding(entry.data.count)))
        }
        out.append(Data(count: 2 * block))
        return out
    }

    /// Reads every entry, refusing links, directories, long names, bad checksums, more than `maximumEntries`
    /// entries, and anything but zero padding after the end marker.
    static func read(_ archive: Data, maximumEntries: Int) throws -> [Entry] {
        let bytes = [UInt8](archive)
        var entries: [Entry] = []
        var offset = 0
        while true {
            guard offset + block <= bytes.count else { throw PayloadError.invalidArchive }
            let head = Array(bytes[offset..<offset + block])
            if head.allSatisfy({ $0 == 0 }) {
                // The end marker is two zero blocks; only more zeros may follow.
                guard offset + 2 * block <= bytes.count, bytes[(offset + block)...].allSatisfy({ $0 == 0 }) else {
                    throw PayloadError.invalidArchive
                }
                return entries
            }
            guard entries.count < maximumEntries, checksumMatches(head),
                  head[Field.type] == regularFile || head[Field.type] == 0,
                  head[Field.magic.prefix(5)].elementsEqual("ustar".utf8),
                  head[Field.unused].allSatisfy({ $0 == 0 }),
                  let size = octal(head[Field.size]),
                  let name = String(bytes: head[Field.name].prefix { $0 != 0 }, encoding: .utf8),
                  !name.isEmpty else { throw PayloadError.invalidArchive }
            offset += block
            guard size <= bytes.count - offset, padding(size) <= bytes.count - offset - size else {
                throw PayloadError.invalidArchive
            }
            entries.append(Entry(name: name, data: Data(bytes[offset..<offset + size])))
            offset += size + padding(size)
        }
    }

    /// Zeros that fill an entry's data out to a whole block.
    private static func padding(_ size: Int) -> Int { (block - size % block) % block }

    private static func header(name: String, size: Int) throws -> Data {
        let nameBytes = Array(name.utf8)
        guard !nameBytes.isEmpty, nameBytes.count <= Field.name.count else { throw PayloadError.invalidFileName }
        var head = [UInt8](repeating: 0, count: block)
        head.replaceSubrange(0..<nameBytes.count, with: nameBytes)
        put("0000644", into: &head, at: Field.mode)
        put("0000000", into: &head, at: Field.owner)
        put("0000000", into: &head, at: Field.group)
        put(String(size, radix: 8).leftPadded(Field.size.count - 1), into: &head, at: Field.size)
        put("00000000000", into: &head, at: Field.modified)
        head[Field.type] = regularFile
        put("ustar", into: &head, at: Field.magic)
        put("00", into: &head, at: Field.version, terminated: false)
        head.replaceSubrange(Field.checksum, with: [UInt8](repeating: 0x20, count: Field.checksum.count))
        // Six octal digits, a NUL and a space, as tar itself writes it.
        let sum = head.reduce(0) { $0 + Int($1) }
        put(String(sum, radix: 8).leftPadded(6), into: &head, at: Field.checksum)
        head[Field.checksum.upperBound - 1] = 0x20
        return Data(head)
    }

    private static func put(_ text: String, into head: inout [UInt8], at field: Range<Int>, terminated: Bool = true) {
        let bytes = Array(text.utf8)
        head.replaceSubrange(field.lowerBound..<field.lowerBound + bytes.count, with: bytes)
        if terminated { head[field.lowerBound + bytes.count] = 0 }
    }

    /// The sum of the header's bytes with the checksum field read as spaces, which is what the field holds.
    static func checksumMatches(_ head: [UInt8]) -> Bool {
        guard let stored = octal(head[Field.checksum]) else { return false }
        return stored == checksum(head)
    }

    static func checksum(_ head: [UInt8]) -> Int {
        head.indices.reduce(0) { $0 + (Field.checksum.contains($1) ? 0x20 : Int(head[$1])) }
    }

    /// Octal digits, ended by a NUL or a space.
    private static func octal(_ field: ArraySlice<UInt8>) -> Int? {
        let digits = field.prefix { $0 != 0 && $0 != 0x20 }
        guard !digits.isEmpty, digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "7")).contains($0) }),
              let text = String(bytes: digits, encoding: .utf8) else { return nil }
        return Int(text, radix: 8)
    }
}

private extension String {
    func leftPadded(_ width: Int) -> String { String(repeating: "0", count: max(0, width - count)) + self }
}
