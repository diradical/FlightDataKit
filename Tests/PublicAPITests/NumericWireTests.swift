// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import FlightDataFormat
import Foundation
import Testing

@Test func exactIntegerFieldsRoundTripThroughPublicJSON() throws {
    for digits in ["9007199254740993", "-9007199254740993", String(Int64.min), String(Int64.max), String(UInt64.max)] {
        let value = try JSONDecoder().decode(ReportValue.self, from: Data(digits.utf8))
        #expect(value.description == digits)
        #expect(String(decoding: try JSONEncoder().encode(value), as: UTF8.self) == digits)
    }
    #expect(ReportValue(UInt.max) == .unsignedInteger(UInt64(UInt.max)))
    let whole: ReportValue = 9_007_199_254_740_993
    #expect(whole == .unsignedInteger(9_007_199_254_740_993))
    #expect(whole != .number(9_007_199_254_740_992))
    #expect(Set<ReportValue>([1, .unsignedInteger(1), .number(1)]) == [1])
    #expect(try JSONDecoder().decode(ReportValue.self, from: Data("0.125".utf8)) == .number(0.125))
    // Beyond 64 bits, or with a fraction, a number is a double: read, never refused.
    for digits in ["18446744073709551617", "-9223372036854775809", "1.5", "-0.001"] {
        let value = try JSONDecoder().decode(ReportValue.self, from: Data(digits.utf8))
        #expect(value == .number(try #require(Double(digits))))
    }
}

@Test func storedFeedbackFieldsRoundTripThroughApplePropertyLists() throws {
    let values: [ReportValue] = [.integer(42), .integer(.min), .integer(.max), .unsignedInteger(.max),
                                 .number(0.125), .number(1e20), .number(-1e22)]
    for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = format
        let stored = try encoder.encode(values)
        #expect(try PropertyListDecoder().decode([ReportValue].self, from: stored) == values)
    }
}

@Test func largeAndSmallDoublesAreSentAndReadAsDoubles() throws {
    for number in [1e23, 6.02214076e23, 3e30, Double(UInt64.max), -1e22, Double.greatestFiniteMagnitude, 1e-300] {
        let value = ReportValue.number(number)
        try ReportContent(title: "Measurement", fields: ["measurement": value]).validate()
        let stored = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(ReportValue.self, from: stored) == value)
    }
    for number in [Double.infinity, -.infinity, .nan] {
        #expect(throws: ReportValidationError.self) {
            try ReportContent(title: "Measurement", fields: ["measurement": .number(number)]).validate()
        }
    }
}
