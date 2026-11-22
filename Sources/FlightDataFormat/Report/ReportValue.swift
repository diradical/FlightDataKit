// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation

/// One of an app's own values on a report, as it is sent: text, a number, or yes or no. In the sealed JSON it is
/// a string, a number or `true`/`false`, so whoever reads the report can sort and filter by it.
///
/// Whole numbers keep every digit in the signed and unsigned 64-bit ranges. Any other number is a `Double`, so send
/// an identifier that can be larger as text.
public enum ReportValue: Hashable, Sendable {
    /// Text, at most 1,000 characters.
    case text(String)
    /// A whole number in the signed 64-bit range.
    case integer(Int64)
    /// A whole number in the unsigned 64-bit range.
    case unsignedInteger(UInt64)
    /// A finite number that may have a fractional part.
    case number(Double)
    /// Yes or no.
    case boolean(Bool)

    /// Text.
    public init(_ text: String) { self = .text(text) }
    /// A whole number.
    public init(_ number: Int) { self = .integer(Int64(number)) }
    /// A whole number.
    public init(_ number: UInt) { self = .unsignedInteger(UInt64(number)) }
    /// A whole number.
    public init(_ number: Int64) { self = .integer(number) }
    /// A whole number.
    public init(_ number: UInt64) { self = .unsignedInteger(number) }
    /// A number that may have a fractional part.
    public init(_ number: Double) { self = .number(number) }
    /// Yes or no.
    public init(_ flag: Bool) { self = .boolean(flag) }
}

extension ReportValue: Codable {
    /// A JSON integer that fits 64 bits is read exactly, as `integer` or `unsignedInteger`; any other number is a
    /// `Double`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .boolean(flag)
        } else if let text = try? container.decode(String.self) {
            self = .text(text)
        } else if let signed = try? container.decode(Int64.self) {
            self = .integer(signed)
        } else if let unsigned = try? container.decode(UInt64.self) {
            self = .unsignedInteger(unsigned)
        } else {
            self = .number(try container.decode(Double.self))
        }
    }

    /// Writes text as a string, a whole number as a JSON integer, and yes or no as `true` or `false`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .integer(let number): try container.encode(number)
        case .unsignedInteger(let number): try container.encode(number)
        case .number(let number): try container.encode(number)
        case .boolean(let flag): try container.encode(flag)
        }
    }
}

extension ReportValue: ExpressibleByStringInterpolation, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                             ExpressibleByBooleanLiteral {
    /// Text written as a literal.
    public init(stringLiteral value: String) { self = .text(value) }
    /// A whole number written as a literal.
    public init(integerLiteral value: Int) { self.init(value) }
    /// A number written as a literal with a fractional part.
    public init(floatLiteral value: Double) { self = .number(value) }
    /// `true` or `false`.
    public init(booleanLiteral value: Bool) { self = .boolean(value) }
}

extension ReportValue: CustomStringConvertible {
    /// As text: a whole number without a decimal point, yes or no as `true` or `false`.
    public var description: String {
        switch self {
        case .text(let text): return text
        case .integer(let number): return String(number)
        case .unsignedInteger(let number): return String(number)
        case .number(let number):
            if let signed = Int64(exactly: number) { return String(signed) }
            if let unsigned = UInt64(exactly: number) { return String(unsigned) }
            return String(number)
        case .boolean(let flag): return flag ? "true" : "false"
        }
    }
}

extension ReportValue {
    // JSON uses the same number for 1, 1.0 and an unsigned 1. Preserve that equality across a round trip.
    private enum Comparison: Hashable {
        case text(String), negative(Int64), whole(UInt64), floating(Double), nan, boolean(Bool)
    }

    private var comparison: Comparison {
        switch self {
        case .text(let text): return .text(text)
        case .boolean(let flag): return .boolean(flag)
        case .integer(let value): return value < 0 ? .negative(value) : .whole(UInt64(value))
        case .unsignedInteger(let value): return .whole(value)
        case .number(let value):
            if let whole = UInt64(exactly: value) { return .whole(whole) }
            if let signed = Int64(exactly: value) { return .negative(signed) }
            return value.isNaN ? .nan : .floating(value)
        }
    }

    /// Whether the two are the same value as JSON writes it: 1, 1.0 and an unsigned 1 are equal.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.comparison == rhs.comparison }
    /// Hashes the value as `==` compares it.
    public func hash(into hasher: inout Hasher) { hasher.combine(comparison) }
}
