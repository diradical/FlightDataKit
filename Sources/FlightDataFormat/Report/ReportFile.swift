// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation

/// A file that goes with a report: a screenshot, a log, the document the person had open.
public struct ReportFile: Identifiable, Hashable, Codable, Sendable {
    /// The file's name, which is unique within a report.
    public var id: String { name }
    /// The name it is sent under: at most 100 bytes, used once in a report even when case is ignored, with no
    /// `/`, `\`, NUL, control or formatting character.
    public let name: String
    /// Its media type, such as `image/png`.
    public let contentType: String
    /// Its bytes.
    public let data: Data

    /// A file sent as `name`, of the media type `contentType`.
    public init(name: String, contentType: String, data: Data) {
        self.name = name
        self.contentType = contentType
        self.data = data
    }
}
