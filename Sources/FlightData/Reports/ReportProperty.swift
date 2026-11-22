// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation

/// How a report type's own properties become fields.
enum ReportProperty {
    /// A property's value as a field.
    enum Reflected {
        case value(ReportValue, FieldKind)
        /// An empty optional.
        case empty
        /// A type a field can't hold.
        case unsupported
    }

    /// The stored properties of `report` as fields, in the order they are declared, with the names of those whose
    /// types a field can't hold.
    static func fields(of report: Any) throws
        -> (fields: [String: ReportValue], descriptions: [FieldDescription], unsupported: [String]) {
        var fields: [String: ReportValue] = [:]
        var descriptions: [FieldDescription] = []
        var unsupported: [String] = []
        for property in Mirror(reflecting: report).children {
            guard let key = property.label else { continue }
            switch try value(property.value, key: key) {
            case .value(let value, let kind):
                fields[key] = value
                descriptions.append(FieldDescription(key: key, label: words(key), kind: kind))
            case .empty:
                break
            case .unsupported:
                unsupported.append(key)
            }
        }
        return (fields, descriptions, unsupported)
    }

    /// A property's value as a field and the kind it is declared as.
    static func value(_ property: Any, key: String) throws -> Reflected {
        let mirror = Mirror(reflecting: property)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first else { return .empty }
            return try value(wrapped.value, key: key)
        }
        switch property {
        case let text as String: return .value(.text(text), .text)
        case let flag as Bool: return .value(.boolean(flag), .boolean)
        case let number as any BinaryInteger:
            if let signed = Int64(exactly: number) { return .value(.integer(signed), .integer) }
            if let unsigned = UInt64(exactly: number) { return .value(.unsignedInteger(unsigned), .integer) }
            throw ReportValidationError(.unrepresentableNumber, "‘\(key)’ exceeds the supported integer range.",
                                        field: key)
        case let number as any BinaryFloatingPoint: return .value(.number(double(number)), .number)
        case let named as any RawRepresentable: return try value(named.rawValue, key: key)
        default: return .unsupported
        }
    }

    private static func double<Number: BinaryFloatingPoint>(_ number: Number) -> Double { Double(number) }

    /// A name in code as words: "usesBillPay" is "Uses Bill Pay", "BankingAnalytics" is "Banking Analytics".
    static func words(_ name: String) -> String {
        var words = ""
        var previous: Character?
        for character in name {
            if character == "_" {
                words.append(" ")
            } else {
                if let previous, character.isUppercase, previous.isLowercase || previous.isNumber { words.append(" ") }
                if previous == nil || previous == "_" {
                    words.append(contentsOf: character.uppercased())
                } else {
                    words.append(character)
                }
            }
            previous = character
        }
        return words
    }
}
