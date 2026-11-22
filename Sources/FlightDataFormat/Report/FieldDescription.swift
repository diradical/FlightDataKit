// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

/// What an app says of one field a report carries: what the field is called, what kind it is and, for a choice,
/// what the chosen option is called. It travels sealed with the report, so the report describes itself.
public struct FieldDescription: Codable, Hashable, Sendable {
    /// The key of the field it describes.
    public var key: String
    /// What the field is called. 1 to 100 characters.
    public var label: String
    /// What kind of value the field holds.
    public var kind: FieldKind
    /// For a choice, what the chosen option is called. At most 100 characters.
    public var option: String?

    /// What the app says of the field `key`.
    public init(key: String, label: String, kind: FieldKind, option: String? = nil) {
        self.key = key
        self.label = label
        self.kind = kind
        self.option = option
    }
}
