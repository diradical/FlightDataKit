// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import CryptoKit
import Foundation
import Testing
@_spi(Testing) @testable import FlightData
@testable import FlightDataFeedback
@testable import FlightDataFormat

struct Keys {
    let privateKey = Curve25519.KeyAgreement.PrivateKey()
    var publicKey: String { Envelope.publicKeyString(privateKey.publicKey) }
    var recipient: Curve25519.KeyAgreement.PublicKey { privateKey.publicKey }
}

let testApp = AppInfo(version: "1.2", build: "34", platform: "macOS", osVersion: "26.0.1",
                      deviceModel: "Mac16,1", locale: "en-US",
                      binaryUUID: "11111111-2222-4333-8444-555555555555")

func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "flightdata-tests-\(UUID().uuidString)")
}

/// An app token of the form Flight Data Recorder gives.
func appToken(_ digit: Character = "a") -> String { "fdk_" + String(repeating: digit, count: 32) }

/// Collects what a container says is wrong with how it is used, which a debug build would stop at.
final class Problems: @unchecked Sendable {
    private let lock = NSLock()
    private var said: [String] = []
    var messages: [String] { lock.withLock { said } }
    func note(_ message: String) { lock.withLock { said.append(message) } }
}

/// A container for tests: it sends to `host` and keeps its files in `directory`, its clock is the test's, its
/// periodic reports are saved at once, and nothing but what the test does sets off a delivery. A problem it reports
/// fails the test unless the test collects it.
func testContainer(_ types: [any FlightDataReport.Type], _ configurations: [FlightDataConfiguration],
                   host: String, directory: URL, clock: TestClock, token: String = appToken(),
                   path: String = "", telemetryEnabled: Bool? = nil,
                   installIDs: any InstallIDStore = MemoryInstallIDStore("install-0123456789"),
                   attestor: any AppAttestor = DeviceAttestor(), triggers: DeliveryTriggers.Inputs = .none,
                   now: (@Sendable () -> Date)? = nil, problems: Problems? = nil) -> FlightDataContainer {
    FlightDataContainer(schema: ReportSchema(types), appToken: token, endpoint: URL(string: "https://\(host)\(path)")!,
                        configurations: configurations, app: testApp, test: true, directory: directory,
                        telemetryEnabled: telemetryEnabled, installIDs: installIDs, session: StubURLProtocol.session(),
                        attestor: attestor, now: now ?? { clock.now }, triggers: triggers, periodicSaveDelay: .zero,
                        problem: { message in
                            if let problems { problems.note(message) } else { Issue.record("\(message)") }
                        })
}

/// A clock a test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// The two parts of a `multipart/form-data` body written by `ReportSender`.
struct Multipart {
    let report: Data
    let payload: Data?
    let payloadFilename: String?

    init(body: Data, contentType: String) throws {
        let boundary = try #require(contentType.components(separatedBy: "boundary=").last)
        let delimiter = Data("--\(boundary)".utf8)
        var report: Data?
        var payload: Data?
        var filename: String?
        var rest = body[...]
        while let range = rest.range(of: delimiter) {
            rest = rest[range.upperBound...]
            if rest.starts(with: Data("--".utf8)) { break }
            let split = try #require(rest.range(of: Data("\r\n\r\n".utf8)))
            let head = String(decoding: rest[..<split.lowerBound], as: UTF8.self)
            let next = try #require(rest[split.upperBound...].range(of: Data("\r\n--\(boundary)".utf8)))
            let content = Data(rest[split.upperBound..<next.lowerBound])
            if head.contains("name=\"report\"") { report = content }
            if head.contains("name=\"payload\"") {
                payload = content
                filename = head.components(separatedBy: "filename=\"").last?.components(separatedBy: "\"").first
            }
            rest = rest[split.upperBound...]
        }
        self.report = try #require(report)
        self.payload = payload
        self.payloadFilename = filename
    }
}

func openText(_ json: [String: Any], keys: Keys) throws -> ReportText {
    let idText = try #require(json["id"] as? String)
    let id = try #require(UUID(uuidString: idText))
    let sealedText = try #require(json["sealed"] as? String)
    let sealed = try #require(Data(base64Encoded: sealedText))
    let plain = try Envelope.open(sealed, using: keys.privateKey, reportID: id, part: .text)
    return try ReportText.decode(plain)
}

/// An install ID that can't be had until the test allows it, so that a container sends nothing meanwhile.
final class HeldInstallID: InstallIDStore, @unchecked Sendable {
    private struct Held: Error {}
    private let lock = NSLock()
    private var allowed = false
    func allow() { lock.withLock { allowed = true } }
    func installID() throws -> String {
        try lock.withLock {
            guard allowed else { throw Held() }
            return "install-0123456789"
        }
    }
}

extension ReportQueue {
    /// What is queued, as a delivery pass would see it now.
    func entries() -> [Entry] { listing(at: Date()).entries }
}

/// Waits until `condition` holds, for at most five seconds.
func waitUntil(_ condition: () async -> Bool) async throws {
    for _ in 0..<500 where !(await condition()) { try await Task.sleep(for: .milliseconds(10)) }
}
