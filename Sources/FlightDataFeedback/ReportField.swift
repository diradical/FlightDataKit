// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import FlightData
import Foundation

/// A question a feedback form asks, or a value the app sets, with what it is called: its key, its label and
/// what its value may be. The key, the label and the kind travel sealed with feedback that carries the field,
/// so Flight Data Recorder shows it as the app described it.
public struct ReportField: Codable, Hashable, Identifiable, Sendable {
    /// What a field's value may be, and so what the form offers for it: `text` and `choice` send text, `integer`
    /// and `number` a number (whole, or with a decimal part), `boolean` yes or no.
    public enum Kind: Codable, Hashable, Sendable {
        /// Text the person types, sent as text.
        case text
        /// A whole number the person types, sent as a number.
        case integer
        /// A number the person types, with a decimal part or without, as their region writes it.
        case number
        /// Yes or no, chosen from a menu.
        case boolean
        /// One of a list of options, chosen from a menu, sent as the option's value.
        case choice([Option])

        /// The kind as it is sealed with a report: the same, without a choice's options.
        var fieldKind: FieldKind {
            switch self {
            case .text: .text
            case .integer: .integer
            case .number: .number
            case .boolean: .boolean
            case .choice: .choice
            }
        }

        /// The kind's name as it is sealed with a report.
        public var name: String { fieldKind.rawValue }
    }

    /// One choice of a `choice` field: the value that is sent, and what the form calls it.
    public struct Option: Codable, Hashable, Identifiable, Sendable {
        /// The value, which is unique within a field's options.
        public var id: String { value }
        /// What is sent when the person chooses this option. 1 to 1,000 characters.
        public let value: String
        /// What the menu shows, and what Flight Data Recorder shows beside the value. 1 to 100 characters.
        public let label: String

        /// - Parameters:
        ///   - value: What is sent when the person chooses this option.
        ///   - label: What the menu shows. Unless you give one, the value.
        public init(_ value: String, label: String? = nil) {
            self.value = value
            self.label = label ?? value
        }
    }

    /// The key, which is unique within a form's questions.
    public var id: String { key }
    /// The name the value is sent under, and what Flight Data Recorder calls the field. 1 to 64 characters.
    public let key: String
    /// What the form and Flight Data Recorder call it. 1 to 100 characters.
    public let label: String
    /// What the value may be, and so the control the form shows for it.
    public let kind: Kind
    /// Whether the form needs an answer before it can be sent. Feedback without a value for a required field
    /// fails validation.
    public let required: Bool
    /// A line under the control, at most 500 characters. It stays in the app.
    public let help: String?
    /// Whether the form asks the person for it. False for a value the app sets itself, which the form lists
    /// under Details.
    public let asked: Bool

    /// - Parameters:
    ///   - key: The name the value is sent under. 1 to 64 characters, unique within the form.
    ///   - label: What the form and Flight Data Recorder call the field. 1 to 100 characters.
    ///   - kind: What the value may be. Text unless you say otherwise.
    ///   - required: Whether the form needs an answer before it can be sent.
    ///   - help: A line under the control, at most 500 characters.
    ///   - asked: Whether the form asks for it. Pass false for a value the app sets itself, which the form shows
    ///     under Details.
    public init(key: String, label: String, kind: Kind = .text, required: Bool = false, help: String? = nil,
                asked: Bool = true) {
        self.key = key
        self.label = label
        self.kind = kind
        self.required = required
        self.help = help
        self.asked = asked
    }

    /// Checks an app's fields together: at most 50, each key once, labels and choices within their bounds.
    public static func validate(_ fields: [Self]) throws {
        guard fields.count <= ReportLimits.fieldCount else {
            throw ReportValidationError(.limitExceeded, "At most 50 fields are supported.", field: "fields")
        }
        var keys: Set<String> = []
        for field in fields {
            try ReportLimits.validateKey(field.key)
            guard keys.insert(field.key).inserted else {
                throw ReportValidationError(.duplicate, "The field key ‘\(field.key)’ is defined more than once.",
                                            field: field.key)
            }
            guard !field.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  field.label.unicodeScalars.count <= 100,
                  (field.help?.unicodeScalars.count ?? 0) <= 500 else {
                throw ReportValidationError(.invalidDescription,
                                            "Fields need a label of 1–100 characters and help of at most 500.",
                                            field: field.key)
            }
            if case .choice(let options) = field.kind {
                guard !options.isEmpty, options.count <= 50,
                      Set(options.map(\.value)).count == options.count,
                      options.allSatisfy({
                          !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                          $0.value.unicodeScalars.count <= ReportLimits.fieldValueLength &&
                          !$0.label.isEmpty && $0.label.unicodeScalars.count <= 100
                      }) else {
                    throw ReportValidationError(.invalidDescription,
                                                "‘\(field.label)’ needs 1–50 distinct, nonempty choices.",
                                                field: field.key)
                }
            }
        }
    }

    /// Checks one value against this field: there when the field is required, and of the field's kind.
    public func validate(value: ReportValue?) throws {
        guard let value, value != .text("") else {
            if required { throw ReportValidationError(.required, "‘\(label)’ is required.", field: key) }
            return
        }
        let valid: Bool = switch (kind, value) {
        case (.text, .text): true
        case (.integer, .number(let number)): number.isFinite && number == number.rounded()
        case (.integer, .integer), (.integer, .unsignedInteger),
             (.number, .integer), (.number, .unsignedInteger): true
        case (.number, .number(let number)): number.isFinite
        case (.boolean, .boolean): true
        case (.choice(let options), .text(let chosen)): options.contains { $0.value == chosen }
        default: false
        }
        guard valid else {
            throw ReportValidationError(.invalidValue, "‘\(label)’ has an invalid value.", field: key)
        }
    }

    /// The value for what a person typed or chose in the form; nil when they left it empty. Throws when it isn't
    /// of the field's kind.
    func value(from entry: String) throws -> ReportValue? {
        let entry = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty else { return nil }
        switch kind {
        case .text, .choice:
            return .text(entry)
        case .integer, .number:
            if let number = Int64(entry) { return .integer(number) }
            if let number = UInt64(entry) { return .unsignedInteger(number) }
            let digits = entry.first == "+" || entry.first == "-" ? entry.dropFirst() : entry[...]
            if !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) {
                throw ReportValidationError(.unrepresentableNumber,
                                            "‘\(label)’ is outside the supported integer range.", field: key)
            }
            if kind == .integer {
                throw ReportValidationError(.invalidValue, "‘\(label)’ needs a whole number.", field: key)
            }
            // As the person's region writes numbers, or with a decimal point.
            guard let number = (try? Double(entry, format: .number)) ?? Double(entry), number.isFinite else {
                throw ReportValidationError(.invalidValue, "‘\(label)’ needs a number.", field: key)
            }
            return .number(number)
        case .boolean:
            guard entry == "true" || entry == "false" else {
                throw ReportValidationError(.invalidValue, "‘\(label)’ has an invalid value.", field: key)
            }
            return .boolean(entry == "true")
        }
    }
}
