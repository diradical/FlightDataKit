// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

#if !os(macOS)
import CoreTransferable
import FlightData
import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Opens the transferred file while its temporary URL is valid. The open descriptor
/// remains readable after the provider removes its temporary directory entry.
private struct PickedPhoto: Transferable {
    let handle: FileHandle

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try PickedPhoto(handle: FileHandle(forReadingFrom: received.file))
        }
    }
}

/// Reads the photos a person picks into files for a report, named Photo 1, Photo 2 and so on.
enum PickedPhotos {
    /// Why a picked photo can't be added.
    enum ImportError: LocalizedError {
        case unreadable(number: Int)
        case unsupportedFormat(number: Int)

        var errorDescription: String? {
            switch self {
            case .unreadable(let number):
                String(localized: "Photo \(number) couldn’t be read.", bundle: .module)
            case .unsupportedFormat(let number):
                String(localized: "Photo \(number) is in a format that can’t be attached.", bundle: .module)
            }
        }
    }

    /// Reads the photos within what is left of a report's budget. `first` is the number the first photo gets.
    static func files(from items: [PhotosPickerItem], first: Int,
                      budget: AttachmentImport) async throws -> [ReportFile] {
        try budget.checkCount(items.count)
        var budget = budget
        var files: [ReportFile] = []
        for (offset, item) in items.enumerated() {
            try Task.checkCancellation()
            guard let photo = try await item.loadTransferable(type: PickedPhoto.self) else {
                throw ImportError.unreadable(number: first + offset)
            }
            defer { try? photo.handle.close() }
            let data = try budget.read(photo.handle)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String),
                  type.conforms(to: .image), let ext = type.preferredFilenameExtension,
                  let mime = type.preferredMIMEType else {
                throw ImportError.unsupportedFormat(number: first + offset)
            }
            let name = String(localized: "Photo \(first + offset)", bundle: .module,
                              comment: "The name of a file made from a picked photo, before its extension.")
            files.append(ReportFile(name: "\(name).\(ext)", contentType: mime, data: data))
        }
        return files
    }
}
#endif
