// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import CryptoKit
import Foundation

/// The files of one report: a gzipped tar whose first entry is `manifest.json`.
///
/// Sealing the archive is ``Envelope``'s job. A valid seal doesn't make an archive safe, so ``unpack(_:)`` bounds
/// everything it reads and checks every file against the manifest.
public enum Payload {
    /// The manifest's `format`.
    public static let formatName = "dev.flightdata.payload"
    /// The manifest's `version`.
    public static let version = 1
    /// The name of the archive's first entry.
    public static let manifestName = "manifest.json"

    struct Manifest: Codable, Equatable {
        struct File: Codable, Equatable {
            let path: String
            let contentType: String
            let bytes: Int
            let sha256: String

            private enum CodingKeys: String, CodingKey {
                case path, bytes, sha256
                case contentType = "content_type"
            }
        }

        let format: String
        let version: Int
        let files: [File]
    }

    /// The most a packed archive may be: the payload envelope's bound less what the envelope adds.
    public static let maximumPackedBytes = Envelope.maximumBytes(for: .payload) - Envelope.overhead

    /// What the tar headers and the manifest may add to the files' own bytes when the most files an archive may
    /// list are unpacked.
    private static let headerAllowance = 2 * 1_024 * 1_024

    /// The most ``unpack(_:)`` expands an archive to.
    static let maximumUnpackedBytes = ReportLimits.attachmentBytes + headerAllowance

    /// Packs files into one archive.
    ///
    /// - Throws: ``PayloadError/invalidFileName`` for a name that isn't safe or is used twice, and
    ///   ``PayloadError/tooLarge`` for too many files, or files that add up to more than an archive may hold.
    public static func pack(_ files: [ReportFile]) throws -> Data {
        guard files.count <= ReportLimits.attachmentCount else { throw PayloadError.tooLarge }
        var names: Set<String> = []
        var total = 0
        for file in files {
            do { try ReportLimits.validateFileName(file.name, used: &names) } catch {
                throw PayloadError.invalidFileName
            }
            total += file.data.count
            guard total <= ReportLimits.attachmentBytes else { throw PayloadError.tooLarge }
        }
        let manifest = Manifest(format: formatName, version: version, files: files.map {
            .init(path: $0.name, contentType: $0.contentType, bytes: $0.data.count, sha256: hash($0.data))
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let entries = [Tar.Entry(name: manifestName, data: try encoder.encode(manifest))]
            + files.map { Tar.Entry(name: $0.name, data: $0.data) }
        let packed = try Gzip.compress(try Tar.write(entries))
        guard packed.count <= maximumPackedBytes else { throw PayloadError.tooLarge }
        return packed
    }

    /// The files of an archive, each checked against the manifest.
    ///
    /// - Throws: ``PayloadError/tooLarge`` for an archive that is, or expands to, more than one may be;
    ///   ``PayloadError/invalidArchive`` for one that isn't this format; and ``PayloadError/manifestMismatch`` for
    ///   files that differ from what the manifest lists.
    public static func unpack(_ archive: Data) throws -> [ReportFile] {
        guard archive.count <= maximumPackedBytes else { throw PayloadError.tooLarge }
        let entries = try Tar.read(try Gzip.decompress(archive, maximumBytes: maximumUnpackedBytes),
                                   maximumEntries: ReportLimits.attachmentCount + 1)
        guard let first = entries.first, first.name == manifestName,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: first.data),
              manifest.format == formatName, manifest.version == version else {
            throw PayloadError.invalidArchive
        }
        let content = entries.dropFirst()
        guard content.reduce(0, { $0 + $1.data.count }) <= ReportLimits.attachmentBytes else {
            throw PayloadError.tooLarge
        }
        guard content.count == manifest.files.count else { throw PayloadError.manifestMismatch }
        var files: [ReportFile] = []
        for (entry, listed) in zip(content, manifest.files) {
            guard ReportLimits.isSafeFileName(listed.path), listed.path != manifestName,
                  entry.name == listed.path, entry.data.count == listed.bytes,
                  hash(entry.data) == listed.sha256 else { throw PayloadError.manifestMismatch }
            files.append(ReportFile(name: listed.path, contentType: listed.contentType, data: entry.data))
        }
        guard Set(files.map(\.name)).count == files.count else { throw PayloadError.manifestMismatch }
        return files
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
