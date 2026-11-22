// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation

/// The bounds of a report. They belong to the format and are the same for every app. Lengths of text count
/// Unicode scalars; names count UTF-8 bytes.
public enum ReportLimits {
    /// The most characters a title may have.
    public static let titleLength = 200
    /// The most characters a description may have.
    public static let descriptionLength = 5_000
    /// The most characters the contact details may have.
    public static let contactLength = 254
    /// The most fields a report may carry.
    public static let fieldCount = 50
    /// The most characters a field's key may have.
    public static let fieldKeyLength = 64
    /// The most characters a field's text value may have.
    public static let fieldValueLength = 1_000
    /// The most characters a field's label, or the label of its chosen option, may have.
    public static let fieldLabelLength = 100
    /// The most bytes a file's name may have.
    public static let attachmentNameBytes = 100
    /// The most bytes a channel's name may have.
    public static let channelBytes = 256
    /// The most a report's title, description, contact details and fields, with what is said of them, may come to
    /// together, as the JSON that is sealed.
    public static let textBytes = Envelope.maximumBytes(for: .text) - Envelope.overhead
    /// The most a report's files may add up to, in bytes. The sealed archive, which is what the server measures,
    /// has the same bound, so files that don't compress may need a little less.
    public static let attachmentBytes = Envelope.maximumBytes(for: .payload)
    /// The most files a report may have, so that opening an archive is bounded.
    public static let attachmentCount = 1_000

    /// Whether a name is flat and fits a tar header. Separators are checked byte by byte, not as Swift characters,
    /// so a slash followed by a combining mark can't pass for something else; control and formatting characters
    /// (such as a right-to-left override, which can disguise an extension) are refused too.
    public static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= attachmentNameBytes && name != "." && name != ".."
            && !name.utf8.contains { $0 == UInt8(ascii: "/") || $0 == UInt8(ascii: "\\") || $0 == 0 }
            && !name.unicodeScalars.contains { [.control, .format].contains($0.properties.generalCategory) }
    }

    /// A safe name, unused in the archive being made even when case is ignored, so that it extracts without
    /// collisions on a case-insensitive volume, and not the manifest's.
    static func validateFileName(_ name: String, used: inout Set<String>) throws {
        let folded = name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        guard isSafeFileName(name), folded != Payload.manifestName else {
            throw ReportValidationError(.invalidName, "Each attachment needs a safe, unreserved filename of at most "
                                        + "\(attachmentNameBytes) bytes.", field: "files")
        }
        guard used.insert(folded).inserted else {
            throw ReportValidationError(.duplicate, "Attachment filenames must be distinct even when case is ignored.",
                                        field: "files")
        }
    }

    /// A channel is any name of 1–256 UTF-8 bytes without control characters.
    package static func validateChannel(_ channel: String) throws {
        guard !channel.isEmpty, channel.utf8.count <= channelBytes,
              !channel.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw ReportValidationError(.invalidName, "A channel must have 1–\(channelBytes) bytes and no control "
                                        + "characters.", field: "channel")
        }
    }

    /// A field's key is 1–64 characters and not blank.
    package static func validateKey(_ key: String) throws {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              key.unicodeScalars.count <= fieldKeyLength else {
            throw ReportValidationError(.invalidName, "Field keys must have 1–\(fieldKeyLength) characters.",
                                        field: key)
        }
    }

    /// At most 50 values, each under a valid key; text of at most 1,000 characters, and numbers JSON can carry.
    package static func validateFields(_ fields: [String: ReportValue]) throws {
        guard fields.count <= fieldCount else {
            throw ReportValidationError(.limitExceeded, "A report can have at most \(fieldCount) fields.",
                                        field: "fields")
        }
        for (key, value) in fields {
            try validateKey(key)
            switch value {
            case .text(let text):
                guard text.unicodeScalars.count <= fieldValueLength else {
                    throw ReportValidationError(.tooLong, "‘\(key)’ must have at most \(count(fieldValueLength)) "
                                                + "characters.", field: key)
                }
            case .number(let number):
                guard number.isFinite else {
                    throw ReportValidationError(.invalidValue, "‘\(key)’ must be a finite number.", field: key)
                }
            case .boolean, .integer, .unsignedInteger:
                break
            }
        }
    }

    /// A limit as the messages write it: `5,000`.
    static func count(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    /// A byte limit as the messages write it: `10 MB`.
    static func megabytes(_ value: Int) -> String {
        "\(count(value / 1_000_000)) MB"
    }
}
