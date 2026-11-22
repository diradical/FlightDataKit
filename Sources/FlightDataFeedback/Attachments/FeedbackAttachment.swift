// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import FlightData
import Foundation

/// One row under "Included in This Report": one or more files, with a line saying what they are. The person
/// can look at what is sent and leave it out, unless it is required.
public struct FeedbackAttachment: Identifiable, Hashable, Sendable {
    /// Made new for each attachment, so two rows with the same files are still two rows.
    public let id: UUID
    /// A line under the file names saying what the files are, such as "The app’s log". It stays in the app;
    /// localize it with `String(localized:)`.
    public let summary: String
    /// Whether the report always includes these files. The row shows a lock instead of a button to remove it.
    public let required: Bool
    /// The files the row stands for, sent under their own names.
    public let files: [ReportFile]

    /// A row for one file.
    ///
    /// - Parameters:
    ///   - file: The file.
    ///   - summary: A line saying what it is. Unless you give one, the row shows only its name.
    ///   - required: Whether the report always includes it.
    public init(_ file: ReportFile, summary: String = "", required: Bool = false) {
        self.init(files: [file], summary: summary, required: required)
    }

    /// A row for files that go together, which the person keeps or leaves out as one.
    ///
    /// - Parameters:
    ///   - files: The files.
    ///   - summary: A line saying what they are. Unless you give one, the row shows only their names.
    ///   - required: Whether the report always includes them.
    public init(files: [ReportFile], summary: String = "", required: Bool = false) {
        self.id = UUID()
        self.files = files
        self.summary = summary
        self.required = required
    }
}
