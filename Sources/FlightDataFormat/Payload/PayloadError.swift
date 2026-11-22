// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation

/// Why a report's files couldn't be packed or unpacked.
public enum PayloadError: Error, Equatable, Sendable, LocalizedError {
    /// A file's name isn't safe, or two files have the same name.
    case invalidFileName
    /// There are too many files, or they are larger together than an archive may be.
    case tooLarge
    /// The archive isn't one this format writes.
    case invalidArchive
    /// The files differ from what the manifest lists.
    case manifestMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidFileName: "An attachment needs a distinct filename of at most 100 safe bytes."
        case .tooLarge: "The attachments are too large to send."
        case .invalidArchive: "The attachment archive is malformed."
        case .manifestMismatch: "The attachment archive does not match its manifest."
        }
    }
}
