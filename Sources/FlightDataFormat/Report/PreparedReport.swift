// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import CryptoKit
import Foundation

/// A report ready to send: the report JSON with its text already sealed, and the sealed archive of its files, if
/// it has any. The report's ID, kind, channel, recipient key ID, test flag and app metadata stay readable.
public struct PreparedReport: Equatable, Sendable {
    /// The report's ID, which the server knows it by.
    public let id: UUID
    /// The `report` part: JSON with the keys `id`, `kind`, `channel`, `app`, `test`, `key_id` and `sealed`.
    public let json: Data
    /// The `payload` part: the sealed archive of the report's files, or nil when it has none.
    public let payload: Data?

    package init(id: UUID, json: Data, payload: Data?) {
        self.id = id
        self.json = json
        self.payload = payload
    }

    /// Validates, packs and seals `content` as a report of `kind` for `channel`. Nothing is trimmed: a report that
    /// doesn't fit is the sender's to shorten.
    ///
    /// - Parameters:
    ///   - content: What the report holds.
    ///   - kind: What sort of report it is.
    ///   - channel: The name the report is routed by: 1 to 256 bytes, without control characters.
    ///   - app: The running app. The report describes it, unless its content names another build.
    ///   - test: Whether the report comes from a test build.
    ///   - recipient: The key the report is sealed to.
    ///   - id: The report's ID.
    /// - Throws: A ``ReportValidationError`` for content or a channel that doesn't fit, and ``EnvelopeError`` or
    ///   ``PayloadError`` when the text or the files can't be sealed.
    public static func make(_ content: ReportContent, kind: ReportKind, channel: String, app: AppInfo, test: Bool,
                            recipient: Curve25519.KeyAgreement.PublicKey, id: UUID = UUID()) throws -> PreparedReport {
        try content.validate()
        try ReportLimits.validateChannel(channel)
        let appValues = try (content.app ?? app).wireValues()
        let text = ReportText(title: content.title, body: content.body, contact: content.contact, labels: [],
                              fields: content.fields, fieldDescriptions: content.fieldDescriptions)
        let sealed = try Envelope.seal(try text.encoded(), to: recipient, reportID: id, part: .text)
        let payload = content.files.isEmpty ? nil : try Envelope.seal(
            try Payload.pack(content.files), to: recipient, reportID: id, part: .payload)
        let wire: [String: Any] = ["id": id.uuidString.lowercased(), "kind": kind.rawValue, "channel": channel,
                                   "app": appValues, "test": test, "key_id": Envelope.keyID(for: recipient),
                                   "sealed": sealed.base64EncodedString()]
        let json = try JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys, .withoutEscapingSlashes])
        return PreparedReport(id: id, json: json, payload: payload)
    }
}
