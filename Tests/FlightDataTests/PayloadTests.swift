// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import CryptoKit
import Foundation
import Security
import Testing
@testable import FlightData
@testable import FlightDataFeedback
@testable import FlightDataFormat

private func file(_ name: String, _ bytes: [UInt8], type: String = "application/octet-stream") -> ReportFile {
    ReportFile(name: name, contentType: type, data: Data(bytes))
}

#if os(macOS)
private func run(_ tool: String, _ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return String(decoding: output, as: UTF8.self)
}
#endif

/// A gzipped tar built by hand, to put things in an archive that `Payload.pack` never would.
private func archive(_ entries: [Tar.Entry]) throws -> Data { try Gzip.compress(try Tar.write(entries)) }

private func manifest(_ files: [Payload.Manifest.File], format: String = Payload.formatName,
                      version: Int = 1) throws -> Tar.Entry {
    .init(name: Payload.manifestName,
          data: try JSONEncoder().encode(Payload.Manifest(format: format, version: version, files: files)))
}

@Test func filesSurviveAPackAndUnpack() throws {
    let files = [
        file("screenshot.png", Array(0...255), type: "image/png"),
        file("notes — ünïcode.txt", Array("héllo\n".utf8), type: "text/plain"),
        file("empty", []),
    ]
    #expect(try Payload.unpack(try Payload.pack(files)) == files)
    #expect(try Payload.unpack(try Payload.pack([])) == [])
}

@Test func packingIsDeterministic() throws {
    let files = [file("a", [1, 2, 3]), file("b", Array(repeating: 7, count: 5_000))]
    #expect(try Payload.pack(files) == Payload.pack(files))
}

@Test func newAttachmentsMustHaveCaseInsensitiveUniqueNamesAndOlderArchivesStillOpen() throws {
    let files = [file("Log.txt", []), file("log.txt", [])]
    #expect(throws: ReportValidationError.self) { try ReportContent(title: "Logs", files: files).validate() }
    #expect(throws: PayloadError.invalidFileName) { try Payload.pack(files) }
    #expect(throws: PayloadError.invalidFileName) { try Payload.pack([file("MANIFEST.JSON", [])]) }
    let listed = files.map {
        Payload.Manifest.File(path: $0.name, contentType: $0.contentType, bytes: 0,
                              sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
    let old = try archive([manifest(listed)] + files.map { Tar.Entry(name: $0.name, data: $0.data) })
    #expect(try Payload.unpack(old) == files)
}

#if os(macOS)
@Test func theSystemTarReadsWhatWeWrite() throws {
    let files = [file("one.bin", Array(repeating: 9, count: 1_000)), file("two.txt", Array("two".utf8))]
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Payload.pack(files).write(to: directory.appending(path: "payload.bin"))
    let listing = try run("/usr/bin/tar", ["-tzf", "payload.bin"], in: directory)
    #expect(listing.split(separator: "\n").map(String.init) == ["manifest.json", "one.bin", "two.txt"])
    try FileManager.default.createDirectory(at: directory.appending(path: "out"), withIntermediateDirectories: true)
    _ = try run("/usr/bin/tar", ["-xzf", "payload.bin", "-C", "out"], in: directory)
    #expect(try Data(contentsOf: directory.appending(path: "out/one.bin")) == files[0].data)
    #expect(try Data(contentsOf: directory.appending(path: "out/two.txt")) == files[1].data)
    let text = try String(contentsOf: directory.appending(path: "out/manifest.json"), encoding: .utf8)
    #expect(text.hasPrefix(#"{"files":[{"bytes":1000,"content_type":"application\/octet-stream""#)
        || text.hasPrefix(#"{"files":[{"bytes":1000,"content_type":"application/octet-stream""#))
}

@Test func anArchiveMadeBySystemToolsOpensOnlyWithOurManifest() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("x".utf8).write(to: directory.appending(path: "a.txt"))
    _ = try run("/usr/bin/tar", ["-czf", "other.tgz", "a.txt"], in: directory)
    let foreign = try Data(contentsOf: directory.appending(path: "other.tgz"))
    #expect(throws: PayloadError.self) { try Payload.unpack(foreign) }
}
#endif

@Test func theGzipTrailerIsChecked() throws {
    let packed = try Payload.pack([file("a", [1, 2, 3])])
    for index in [packed.count - 1, packed.count - 5] {
        var broken = packed
        broken[index] ^= 0x01
        #expect(throws: PayloadError.invalidArchive) { try Payload.unpack(broken) }
    }
    #expect(throws: PayloadError.invalidArchive) { try Payload.unpack(packed.dropLast()) }
    #expect(throws: PayloadError.invalidArchive) { try Payload.unpack(packed + [0]) }
    #expect(throws: PayloadError.invalidArchive) { try Payload.unpack(Data()) }
    #expect(throws: PayloadError.invalidArchive) { try Payload.unpack(Data(repeating: 0x1f, count: 64)) }
}

@Test func aFileThatDoesNotMatchItsManifestIsRefused() throws {
    let good = Payload.Manifest.File(path: "a", contentType: "text/plain", bytes: 3,
                                     sha256: "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81")
    let data = Tar.Entry(name: "a", data: Data([1, 2, 3]))
    #expect(try Payload.unpack(try archive([manifest([good]), data])).count == 1)
    let altered = Tar.Entry(name: "a", data: Data([1, 2, 4]))
    #expect(throws: PayloadError.manifestMismatch) { try Payload.unpack(try archive([manifest([good]), altered])) }
    let wrongSize = Payload.Manifest.File(path: "a", contentType: "text/plain", bytes: 4, sha256: good.sha256)
    #expect(throws: PayloadError.manifestMismatch) { try Payload.unpack(try archive([manifest([wrongSize]), data])) }
    #expect(throws: PayloadError.manifestMismatch) {
        try Payload.unpack(try archive([manifest([good]), data, Tar.Entry(name: "extra", data: Data())]))
    }
    #expect(throws: PayloadError.manifestMismatch) {
        try Payload.unpack(try archive([manifest([good, good]), data, data]))
    }
    #expect(throws: PayloadError.invalidArchive) { try Payload.unpack(try archive([data, try manifest([good])])) }
    #expect(throws: PayloadError.invalidArchive) {
        try Payload.unpack(try archive([try manifest([good], format: "other"), data]))
    }
    #expect(throws: PayloadError.invalidArchive) {
        try Payload.unpack(try archive([try manifest([good], version: 2), data]))
    }
}

@Test func unsafeNamesInAManifestAreRefused() throws {
    // The tar header holds each of these names; only the manifest's check refuses them.
    for name in ["../escape", "a/b", "manifest.json", "..", "a\\b", "invoice\u{202E}fdp.exe"] {
        let listed = Payload.Manifest.File(path: name, contentType: "text/plain", bytes: 0,
                                           sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let entries = try archive([manifest([listed]), Tar.Entry(name: name, data: Data())])
        #expect(throws: PayloadError.manifestMismatch, "\(name.debugDescription)") { try Payload.unpack(entries) }
    }
}

@Test func namesThatHideASeparatorOrDisguiseTheirTextAreRefused() throws {
    // A slash or backslash followed by a combining mark is one Swift character, so these are checked as bytes.
    for name in ["../\u{301}evil.sh", "a/\u{301}b", "a\\\u{301}b", "a\u{0}b", "line\nbreak", "invoice\u{202E}fdp.exe"] {
        #expect(!ReportLimits.isSafeFileName(name), "\(name.debugDescription)")
        #expect(throws: PayloadError.invalidFileName) { try Payload.pack([file(name, [1])]) }
        #expect(throws: ReportValidationError.self) {
            let named = ReportFile(name: name, contentType: "text/plain", data: Data([1]))
            try ReportContent(title: "t", files: [named]).validate()
        }
    }
    #expect(ReportLimits.isSafeFileName("Résumé – final.pdf"))
}

@Test func packingRefusesWhatCannotBeSentAsIs() {
    #expect(throws: PayloadError.invalidFileName) { try Payload.pack([file("a", []), file("a", [])]) }
    #expect(throws: PayloadError.invalidFileName) { try Payload.pack([file("manifest.json", [])]) }
    #expect(throws: PayloadError.invalidFileName) { try Payload.pack([file("a/b", [])]) }
    #expect(throws: PayloadError.invalidFileName) { try Payload.pack([file("", [])]) }
    #expect(throws: PayloadError.invalidFileName) { try Payload.pack([file(String(repeating: "n", count: 101), [])]) }
    // How many files there are is not bounded, short of what one archive may list.
    #expect(throws: Never.self) { try Payload.pack((0...50).map { file("f\($0)", []) }) }
    #expect(throws: PayloadError.tooLarge) {
        try Payload.pack((0...ReportLimits.attachmentCount).map { file("f\($0)", []) })
    }
    #expect(throws: PayloadError.tooLarge) {
        try Payload.pack([ReportFile(name: "big", contentType: "x/y",
                                       data: Data(count: ReportLimits.attachmentBytes + 1))])
    }
    #expect(throws: Never.self) { try Payload.pack([file(String(repeating: "n", count: 100), [])]) }
}

@Test func incompressibleAttachmentsThatPassThePackedBoundAreRefused() throws {
    var noise = Data(count: ReportLimits.attachmentBytes)
    let made = noise.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
    try #require(made == errSecSuccess)
    #expect(throws: PayloadError.tooLarge) {
        try Payload.pack([ReportFile(name: "noise", contentType: "x/y", data: noise)])
    }
}

@Test func anArchiveThatExpandsPastTheLimitIsRefusedWithoutBeingExpanded() throws {
    let bomb = try Gzip.compress(Data(count: Payload.maximumUnpackedBytes + 1))
    #expect(bomb.count < 100_000)
    #expect(throws: PayloadError.tooLarge) { try Payload.unpack(bomb) }
}

#if os(macOS)
@Test func gzipAgreesWithTheSystemTool() throws {
    let plain = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Gzip.compress(plain).write(to: directory.appending(path: "x.gz"))
    _ = try run("/usr/bin/gunzip", ["-k", "x.gz"], in: directory)
    #expect(try Data(contentsOf: directory.appending(path: "x")) == plain)
    try FileManager.default.removeItem(at: directory.appending(path: "x.gz"))
    _ = try run("/usr/bin/gzip", ["-k", "-n", "-9", "x"], in: directory)
    #expect(try Gzip.decompress(Data(contentsOf: directory.appending(path: "x.gz")), maximumBytes: 1_000_000) == plain)
}
#endif

// MARK: - Archives the kit never writes

/// The archive's first header with `change` made to it, and its checksum made right again unless `keepChecksum`.
private func altered(_ entries: [Tar.Entry], keepChecksum: Bool = false,
                     _ change: (inout [UInt8]) -> Void) throws -> Data {
    var bytes = [UInt8](try Tar.write(entries))
    var head = Array(bytes[0..<Tar.block])
    change(&head)
    if !keepChecksum {
        let digits = Array(String(Tar.checksum(head), radix: 8).utf8)
        let field = [UInt8](repeating: UInt8(ascii: "0"), count: 6 - digits.count) + digits + [0, 0x20]
        head.replaceSubrange(Tar.Field.checksum, with: field)
    }
    bytes.replaceSubrange(0..<Tar.block, with: head)
    return Data(bytes)
}

@Test func onlyRegularFilesAreRead() throws {
    let entry = Tar.Entry(name: "a", data: Data("x".utf8))
    #expect(try Tar.read(try altered([entry]) { _ in }, maximumEntries: 1) == [entry])
    // A directory, a hard link, a symbolic link, a device, and a long name's extension header.
    for type in ["5", "1", "2", "3", "L", "x"] {
        let archive = try altered([entry]) { $0[Tar.Field.type] = Character(type).asciiValue! }
        #expect(throws: PayloadError.invalidArchive, "type \(type)") { try Tar.read(archive, maximumEntries: 1) }
    }
    let linked = try altered([entry]) { $0.replaceSubrange(Tar.Field.unused.prefix(4), with: Array("link".utf8)) }
    #expect(throws: PayloadError.invalidArchive) { try Tar.read(linked, maximumEntries: 1) }
}

@Test func aHeaderWithTheWrongChecksumIsRefused() throws {
    let entry = Tar.Entry(name: "a", data: Data("x".utf8))
    let renamed = try altered([entry], keepChecksum: true) { $0[0] = UInt8(ascii: "b") }
    #expect(throws: PayloadError.invalidArchive) { try Tar.read(renamed, maximumEntries: 1) }
    let unreadable = try altered([entry], keepChecksum: true) {
        $0.replaceSubrange(Tar.Field.checksum, with: Array("9999999 ".utf8))
    }
    #expect(throws: PayloadError.invalidArchive) { try Tar.read(unreadable, maximumEntries: 1) }
}

@Test func anArchiveListingMoreThanItMayIsRefused() throws {
    let entries = (0...ReportLimits.attachmentCount).map { Tar.Entry(name: "f\($0)", data: Data()) }
    #expect(try Tar.read(Tar.write(entries), maximumEntries: ReportLimits.attachmentCount + 1).count == 1_001)
    let tooMany = try Gzip.compress(try Tar.write(entries + [Tar.Entry(name: "extra", data: Data())]))
    #expect(throws: PayloadError.invalidArchive) { try Payload.unpack(tooMany) }
}

@Test func onlyZerosMayFollowTheEndOfAnArchive() throws {
    let archive = try Tar.write([Tar.Entry(name: "a", data: Data("x".utf8))])
    #expect(try Tar.read(archive + Data(count: 10 * Tar.block), maximumEntries: 1).count == 1)
    #expect(throws: PayloadError.invalidArchive) { try Tar.read(archive + Data([1]), maximumEntries: 1) }
    #expect(throws: PayloadError.invalidArchive) { try Tar.read(archive.dropLast(Tar.block), maximumEntries: 1) }
    #expect(throws: PayloadError.invalidArchive) { try Tar.read(archive.dropLast(3 * Tar.block), maximumEntries: 1) }
}

@Test func filesTotallingMoreThanAReportMayHaveAreRefusedWhenUnpacked() throws {
    let half = Data(count: ReportLimits.attachmentBytes / 2 + 1)
    let hash = SHA256.hash(data: half).map { String(format: "%02x", $0) }.joined()
    let listed = ["a", "b"].map { Payload.Manifest.File(path: $0, contentType: "x/y", bytes: half.count, sha256: hash) }
    let packed = try archive([manifest(listed), Tar.Entry(name: "a", data: half), Tar.Entry(name: "b", data: half)])
    #expect(packed.count <= Payload.maximumPackedBytes)
    #expect(throws: PayloadError.tooLarge) { try Payload.unpack(packed) }
}

/// A gzip header carrying `flags`, then `fields`, before the deflate stream of what `Gzip` wrote.
private func gzip(_ plain: Data, flags: UInt8, fields: [UInt8]) throws -> Data {
    let written = [UInt8](try Gzip.compress(plain))
    var header = Array(written[0..<10])
    header[3] = flags
    return Data(header + fields + written[10...])
}

@Test func gzipHeaderFieldsAreReadAndReservedFlagsRefused() throws {
    let plain = Data("payload".utf8)
    let extra: [UInt8] = [4, 0, 1, 2, 3, 4]
    let name = Array("payload.tar\0".utf8)
    let comment = Array("made by hand\0".utf8)
    #expect(try Gzip.decompress(gzip(plain, flags: 0x04, fields: extra), maximumBytes: 100) == plain)
    #expect(try Gzip.decompress(gzip(plain, flags: 0x08, fields: name), maximumBytes: 100) == plain)
    #expect(try Gzip.decompress(gzip(plain, flags: 0x1c, fields: extra + name + comment), maximumBytes: 100) == plain)
    // The header CRC is the low 16 bits of the CRC-32 of the header before it.
    var header = [UInt8](try Gzip.compress(plain))[0..<10]
    header[3] = 0x0a
    let crc = UInt16(truncatingIfNeeded: CRC32.checksum(Array(header) + name))
    let checked = try gzip(plain, flags: 0x0a, fields: name + [UInt8(crc & 0xff), UInt8(crc >> 8)])
    #expect(try Gzip.decompress(checked, maximumBytes: 100) == plain)
    let wrong = try gzip(plain, flags: 0x0a, fields: name + [UInt8(crc & 0xff) ^ 1, UInt8(crc >> 8)])
    #expect(throws: PayloadError.invalidArchive) { try Gzip.decompress(wrong, maximumBytes: 100) }
    for reserved: UInt8 in [0x20, 0x40, 0x80] {
        #expect(throws: PayloadError.invalidArchive) {
            try Gzip.decompress(gzip(plain, flags: reserved, fields: []), maximumBytes: 100)
        }
    }
    // An unterminated name, or extra data longer than the stream, runs into the trailer.
    let named: [UInt8] = [0x1f, 0x8b, 0x08, 0x08, 0, 0, 0, 0, 0, 0xff]
    let unterminated = Data(named + Array("name".utf8) + Array(repeating: 1, count: 8))
    #expect(throws: PayloadError.invalidArchive) { try Gzip.decompress(unterminated, maximumBytes: 100) }
    #expect(throws: PayloadError.invalidArchive) {
        try Gzip.decompress(gzip(plain, flags: 0x04, fields: [0xff, 0xff]), maximumBytes: 100)
    }
}
