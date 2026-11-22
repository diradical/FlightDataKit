// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation

/// A report's text, as it is sealed in the report's text envelope: JSON of these fields, keys sorted.
///
/// A tool that holds the private key opens the envelope with ``Envelope/open(_:using:reportID:part:)`` and reads
/// it with ``decode(_:)``.
public struct ReportText: Codable, Equatable, Sendable {
    /// One line saying what the report is.
    public var title: String
    /// The longer text: what happened, in the person's words.
    public var body: String
    /// How to reach the person, if they gave it.
    public var contact: String?
    /// Labels the developer's own tools give a report once it has arrived. An app sends none: the kit always
    /// writes an empty array.
    public var labels: [String]
    /// The app's own values by key: strings, numbers and `true` or `false`.
    public var fields: [String: ReportValue]
    /// What the app says of the fields here, in the order to show them. Written under the key `schema`, and left
    /// out when empty.
    public var fieldDescriptions: [FieldDescription]

    /// A report's text.
    public init(title: String, body: String, contact: String? = nil, labels: [String] = [],
                fields: [String: ReportValue] = [:], fieldDescriptions: [FieldDescription] = []) {
        self.title = title
        self.body = body
        self.contact = contact
        self.labels = labels
        self.fields = fields
        self.fieldDescriptions = fieldDescriptions
    }

    private enum CodingKeys: String, CodingKey {
        case title, body, contact, labels, fields
        case fieldDescriptions = "schema"
        /// What `fields` was called before values had types, when every value was a string.
        case earlierFields = "metadata"
    }

    /// Reads the text. Text written before values had types, with every value a string under `metadata`, still
    /// reads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        contact = try container.decodeIfPresent(String.self, forKey: .contact)
        labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
        fields = try container.decodeIfPresent([String: ReportValue].self, forKey: .fields)
            ?? container.decodeIfPresent([String: ReportValue].self, forKey: .earlierFields) ?? [:]
        fieldDescriptions = try container.decodeIfPresent([FieldDescription].self, forKey: .fieldDescriptions) ?? []
    }

    /// Writes the text, leaving out `contact` when there is none and `schema` when it is empty.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encodeIfPresent(contact, forKey: .contact)
        try container.encode(labels, forKey: .labels)
        try container.encode(fields, forKey: .fields)
        if !fieldDescriptions.isEmpty { try container.encode(fieldDescriptions, forKey: .fieldDescriptions) }
    }

    /// The JSON that is sealed: keys sorted, slashes as they are.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Reads the JSON of an opened text envelope.
    public static func decode(_ data: Data) throws -> ReportText {
        try JSONDecoder().decode(ReportText.self, from: data)
    }
}
