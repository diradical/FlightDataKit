// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import CryptoKit
import Foundation
import Security
import Testing
@_spi(Testing) @testable import FlightData
@testable import FlightDataFeedback
@testable import FlightDataFormat

@Test func aPreparedReportShowsTheServerOnlyWhatItMayRead() throws {
    let keys = Keys()
    let id = UUID()
    let feedback = ReportContent(title: "Crash on open", body: "It closes.", contact: "me@example.test",
                                 fields: ["area": "arrows"])
    let report = try PreparedReport.make(feedback, kind: .feedback, channel: "billing", app: testApp, test: true,
                                         recipient: keys.recipient, id: id)
    let json = try #require(JSONSerialization.jsonObject(with: report.json) as? [String: Any])
    #expect(Set(json.keys) == ["id", "kind", "channel", "app", "test", "key_id", "sealed"])
    #expect(json["channel"] as? String == "billing")
    #expect(json["id"] as? String == id.uuidString.lowercased())
    #expect(json["kind"] as? String == "feedback")
    #expect(json["test"] as? Bool == true)
    #expect(json["key_id"] as? String == Envelope.keyID(for: keys.privateKey.publicKey))
    let app = try #require(json["app"] as? [String: String])
    #expect(app == ["version": "1.2", "build": "34", "platform": "macOS", "os_version": "26.0.1",
                    "device_model": "Mac16,1", "locale": "en-US",
                    "binary_uuid": "11111111-2222-4333-8444-555555555555"])
    #expect(report.payload == nil)
    // Nothing the person wrote appears anywhere readable.
    let wire = String(decoding: report.json, as: UTF8.self)
    for secret in ["Crash on open", "It closes.", "me@example.test", "arrows"] { #expect(!wire.contains(secret)) }
    let text = try openText(json, keys: keys)
    #expect(text == ReportText(title: "Crash on open", body: "It closes.", contact: "me@example.test",
                               labels: [], fields: ["area": "arrows"]))
}

@Test func attachmentsAreSealedAsAPayloadThatOpensToTheSameFiles() throws {
    let keys = Keys()
    let id = UUID()
    let files = [ReportFile(name: "doc.txt", contentType: "text/plain", data: Data("hello".utf8))]
    let report = try PreparedReport.make(ReportContent(title: "t", body: "b", files: files), kind: .feedback,
                                         channel: "billing", app: testApp, test: false,
                                         recipient: keys.recipient, id: id)
    let sealed = try #require(report.payload)
    let opened = try Envelope.open(sealed, using: keys.privateKey, reportID: id, part: .payload)
    #expect(try Payload.unpack(opened) == files)
    #expect(throws: EnvelopeError.authenticationFailed) {
        try Envelope.open(sealed, using: keys.privateKey, reportID: UUID(), part: .payload)
    }
}

@Test func aReportsTextSharesOneBoundThatIsCheckedBeforeAnythingIsSealed() throws {
    let keys = Keys()
    let longest = String(repeating: "🛩", count: ReportLimits.descriptionLength)
    #expect(throws: Never.self) {
        try PreparedReport.make(ReportContent(title: "t", body: longest), kind: .feedback, channel: "billing",
                                app: testApp, test: false,
                                recipient: keys.recipient)
    }
    #expect(throws: ReportValidationError.self) { try ReportContent(title: "t", body: longest + "x").validate() }
    // Each part is within its own limit, but together they pass the bytes the sealed text may have. The report is
    // refused, not cut.
    let fields = Dictionary(uniqueKeysWithValues: (0..<5).map {
        ("key\($0)", ReportValue.text(String(repeating: "🛩", count: ReportLimits.fieldValueLength)))
    })
    #expect(throws: ReportValidationError(.limitExceeded,
                                          "The report’s text is too long to send. Shorten the description.")) {
        try ReportContent(title: "t", body: longest, fields: fields).validate()
    }
}

@Test func invalidReportsAndKeysAreRefusedBeforeAnythingIsSealed() throws {
    let keys = Keys()
    #expect(throws: ReportValidationError.self) {
        try PreparedReport.make(ReportContent(title: "", body: "b"), kind: .feedback, channel: "billing", app: testApp,
                                test: false, recipient: keys.recipient)
    }
    let zero = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(repeating: 0, count: 32))
    #expect(throws: EnvelopeError.invalidPublicKey) {
        try PreparedReport.make(ReportContent(title: "t", body: "b"), kind: .feedback, channel: "billing", app: testApp,
                                test: false, recipient: zero)
    }
}

@Test func aChannelIsAnyNameOfUpTo256BytesWithoutControlCharacters() throws {
    let keys = Keys()
    for channel in ["Billing", "Sécurité / payments", String(repeating: "é", count: 128)] {
        #expect(throws: Never.self) {
            try PreparedReport.make(ReportContent(title: "t", body: "b"), kind: .feedback, channel: channel,
                                    app: testApp, test: false,
                                    recipient: keys.recipient)
        }
    }
    for channel in ["", String(repeating: "é", count: 129), "a\nb", "a\u{7}b"] {
        #expect(throws: ReportValidationError.self) {
            try PreparedReport.make(ReportContent(title: "t", body: "b"), kind: .feedback, channel: channel,
                                    app: testApp, test: false,
                                    recipient: keys.recipient)
        }
    }
}

@Test func appInfoCutsLongValuesAndDropsEmptyOnes() throws {
    let info = AppInfo(version: String(repeating: "1", count: 40), build: "", platform: "macOS")
    #expect(info.version.count == 32)
    #expect(info.build == nil)
    #expect(try info.wireValues() == ["version": String(repeating: "1", count: 32), "platform": "macOS"])
}

@Test func crashBuildMetadataIsValidatedBeforeQueueing() throws {
    let keys = Keys()
    func prepare(_ app: AppInfo) throws -> PreparedReport {
        try PreparedReport.make(ReportContent(title: "Crash"), kind: .crash, channel: "Crash",
                                app: app, test: true, recipient: keys.recipient)
    }
    var app = AppInfo(version: "1", binaryUUID: "AABBCCDDEEFF412381239123456789AB")
    let report = try prepare(app)
    let wire = try #require(JSONSerialization.jsonObject(with: report.json) as? [String: Any])
    #expect((wire["app"] as? [String: String])?["binary_uuid"] == "aabbccdd-eeff-4123-8123-9123456789ab")
    app.binaryUUID = "invalid"
    #expect(throws: ReportValidationError.self) { try prepare(app) }
    app.binaryUUID = nil
    app.osVersion = "abc\0def"
    #expect(throws: ReportValidationError.self) { try prepare(app) }
    #expect(throws: ReportValidationError.self) { try prepare(AppInfo(version: "")) }
}

@Test func expandedUppercaseLettersAreSafeInDefaultReportLabels() throws {
    struct Report: ReflectedFlightDataReport {
        static let name = "ßeta_ﬃeld"
        var count_ßeta = 0
    }
    let content = try Report().content()
    #expect(content.title == "SSeta FFIeld")
    #expect(content.fieldDescriptions.first?.label == "Count SSeta")
}

@Test func integerFieldsPreserveExactValuesThroughReflectionAndTheForm() throws {
    struct Report: ReflectedFlightDataReport { var reference: UInt64 }
    let question = ReportField(key: "reference", label: "Reference", kind: .integer)
    for signed: Int in [9_007_199_254_740_993, Int.max, Int.min] {
        let value = try #require(try question.value(from: String(signed)))
        #expect(value == ReportValue(signed))
        #expect(String(decoding: try JSONEncoder().encode(value), as: UTF8.self) == String(signed))
    }
    let reflected = try #require(try Report(reference: .max).content().fields["reference"])
    #expect(reflected == .unsignedInteger(.max))
    let encoded = try JSONEncoder().encode(reflected)
    #expect(String(decoding: encoded, as: UTF8.self) == String(UInt64.max))
    #expect(try JSONDecoder().decode(ReportValue.self, from: encoded) == reflected)
}

@Test func theRunningAppDescribesItself() {
    let info = AppInfo.current()
    #expect(!info.version.isEmpty)
    #if os(macOS)
    #expect(info.platform == "macOS")
    #elseif os(iOS)
    #expect(info.platform == "iOS")
    #endif
    #expect(info.deviceModel?.isEmpty == false)
    #expect(info.osVersion?.split(separator: ".").count == 3)
    if let uuid = info.binaryUUID { #expect(UUID(uuidString: uuid) != nil) }
    #expect(info.binaryUUID != nil)
}

@Test func installIDsAreThirtyTwoRandomLowercaseHexDigits() throws {
    let store = MemoryInstallIDStore()
    let first = try store.installID()
    #expect(first == (try store.installID()))
    #expect(InstallID.make() != InstallID.make())
    for id in [first, InstallID.make()] { #expect(id.wholeMatch(of: /[0-9a-f]{32}/) != nil, "\(id)") }
    #expect(try MemoryInstallIDStore("fixed-id-1234").installID() == "fixed-id-1234")
}

@Test func theReportsOwnBuildIsTheOneItDescribes() throws {
    let keys = Keys()
    let crashed = AppInfo(version: "0.9", build: "7")
    let report = try PreparedReport.make(ReportContent(title: "Crash", app: crashed), kind: .crash, channel: "Crash",
                                         app: testApp, test: true, recipient: keys.recipient)
    let wire = try #require(JSONSerialization.jsonObject(with: report.json) as? [String: Any])
    #expect(wire["app"] as? [String: String] == ["version": "0.9", "build": "7"])
}

/// Whether this process may use the keychain: a hostless test bundle on iOS has no keychain entitlement.
private let keychainIsReachable: Bool = {
    let service = "dev.flightdata.kit.tests.probe.\(UUID().uuidString)"
    defer { deleteInstallID(service: service) }
    return (try? KeychainInstallIDStore(service: service).installID()) != nil
}()

@Test(.enabled(if: keychainIsReachable, "The keychain needs a host app on iOS"))
func theKeychainKeepsOneInstallIDPerService() throws {
    let service = "dev.flightdata.kit.tests.\(UUID().uuidString)"
    defer {
        deleteInstallID(service: service)
        deleteInstallID(service: service + ".other")
    }
    let first = try KeychainInstallIDStore(service: service).installID()
    #expect(try KeychainInstallIDStore(service: service).installID() == first)
    #expect(try KeychainInstallIDStore(service: service + ".other").installID() != first)
}

/// Removes a test's install ID from whichever keychain the store put it in: the data-protection keychain
/// under an entitled test host, the login keychain under `swift test`.
private func deleteInstallID(service: String) {
    for dataProtection in [true, false] {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                       kSecAttrAccount: KeychainInstallIDStore.account,
                       kSecUseDataProtectionKeychain: dataProtection] as CFDictionary)
    }
}
