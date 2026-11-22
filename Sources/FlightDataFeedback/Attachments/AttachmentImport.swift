// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import FlightData
import Foundation
import UniformTypeIdentifiers

/// The bytes and file slots still available after earlier attachments.
struct AttachmentImport: Sendable {
    private var remainingBytes = ReportLimits.attachmentBytes
    private var remainingFiles = ReportLimits.attachmentCount

    init(including files: [ReportFile]) throws {
        try ReportContent(title: "Attachments", files: files).validate()
        remainingFiles -= files.count
        remainingBytes -= files.reduce(0) { $0 + $1.data.count }
    }

    /// Throws when `count` more files would pass the most a report can include.
    func checkCount(_ count: Int) throws {
        guard count <= remainingFiles else {
            throw ReportValidationError(.limitExceeded,
                                        "A report can include at most \(ReportLimits.attachmentCount) files.",
                                        field: "files")
        }
    }

    /// Reads through EOF, including when a file provider returns a short read.
    mutating func read(_ handle: FileHandle) throws -> Data {
        try checkCount(1)
        var data = Data()
        while true {
            try Task.checkCancellation()
            let allowance = remainingBytes - data.count
            guard let chunk = try handle.read(upToCount: min(65_536, allowance + 1)), !chunk.isEmpty else { break }
            guard chunk.count <= allowance else {
                throw ReportValidationError(.limitExceeded, "Attachments must total at most 10 MB.", field: "files")
            }
            data.append(chunk)
        }
        remainingBytes -= data.count
        remainingFiles -= 1
        return data
    }

    func files(at urls: [URL]) async throws -> [ReportFile] {
        try checkCount(urls.count)
        var budget = self
        return try urls.map { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try budget.read(handle)
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            return ReportFile(name: url.lastPathComponent, contentType: type, data: data)
        }
    }
}
