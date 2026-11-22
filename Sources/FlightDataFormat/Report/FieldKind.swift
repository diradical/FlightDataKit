// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

/// What kind of value a field holds, as an app describes it: written in the sealed text as `text`, `integer`,
/// `number`, `boolean` or `choice`.
public enum FieldKind: Hashable, Sendable {
    /// Text the person typed or the app set.
    case text
    /// A whole number.
    case integer
    /// A number that may have a fractional part.
    case number
    /// Yes or no.
    case boolean
    /// Text that is one of a set of options.
    case choice
    /// A kind this version doesn't know, as it was written, so that text read and sealed again keeps it.
    case unknown(String)
}

extension FieldKind: RawRepresentable, Codable {
    /// The kind written as `name`; ``unknown(_:)`` for a name this version doesn't know.
    public init(rawValue name: String) {
        switch name {
        case "text": self = .text
        case "integer": self = .integer
        case "number": self = .number
        case "boolean": self = .boolean
        case "choice": self = .choice
        default: self = .unknown(name)
        }
    }

    /// The kind's name as it is written.
    public var rawValue: String {
        switch self {
        case .text: "text"
        case .integer: "integer"
        case .number: "number"
        case .boolean: "boolean"
        case .choice: "choice"
        case .unknown(let name): name
        }
    }
}
