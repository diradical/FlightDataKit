// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import FlightDataFormat
import Foundation

/// The reports waiting to be sent: one folder per report under `root`, holding the report JSON, the sealed payload
/// if there is one, and when to try it next. What is in a report is already sealed. Calls are not synchronized;
/// `FlightDataContainer` makes them one at a time.
struct ReportQueue: Sendable {
    /// When a report was queued, how often it was tried, and when it may be tried next.
    struct State: Codable, Equatable, Sendable {
        var created: Date
        var attempts: Int
        var notBefore: Date
        /// Whether the report has a payload, so that a payload file that went missing isn't taken for none.
        var hasPayload: Bool
        /// Whether the last attempt failed for want of a connection and the wait is only the kit's own backoff, so
        /// that a returning network or app may cut it short. False when the server set the wait.
        var retriesWhenReachable = false
    }

    struct Entry: Equatable, Sendable {
        let id: UUID
        var state: State
        /// Its state couldn't be read, so this one was made in its place; a delivery pass saves it.
        var recovered = false
    }

    /// What is in the queue, as it was read. Reading it changes nothing on disk.
    struct Listing {
        var entries: [Entry] = []
        /// Reports that are there but couldn't be read.
        var unreadableEntries = 0
        /// The queue's folder is there but couldn't be read.
        var rootUnavailable = false
        /// Folders a delivery pass removes: writes that never finished, and reports without their JSON.
        var leftovers: [URL] = []

        /// How many reports are waiting, readable or not.
        var count: Int { entries.count + unreadableEntries }

        var hasStorageProblem: Bool { rootUnavailable || unreadableEntries > 0 }

        /// When the first report not in `deferred` may be tried.
        func nextAttempt(excluding deferred: Set<UUID>) -> Date? {
            entries.filter { !deferred.contains($0.id) }.map(\.state.notBefore).min()
        }
    }

    /// How long a report is kept before it is given up.
    static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    let root: URL

    private static let reportFile = "report.json"
    private static let payloadFile = "payload.bin"
    private static let stateFile = "state.json"
    private static let unfinished = ".new-"

    /// Writes the report beside the others, whole or not at all. A report already queued is left alone.
    func enqueue(_ report: PreparedReport, now: Date) throws {
        let manager = FileManager.default
        try Storage.makeDirectory(root)
        let final = folder(report.id)
        guard !contains(report.id) else { return }
        let temporary = root.appending(path: Self.unfinished + UUID().uuidString)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        do {
            try Storage.write(report.json, to: temporary.appending(path: Self.reportFile))
            if let payload = report.payload {
                try Storage.write(payload, to: temporary.appending(path: Self.payloadFile))
            }
            let state = State(created: now, attempts: 0, notBefore: now, hasPayload: report.payload != nil)
            try write(state, to: temporary)
            try manager.moveItem(at: temporary, to: final)
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    /// Whether the report is queued.
    func contains(_ id: UUID) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: folder(id).path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// The readable reports, oldest first. A report whose state is missing or malformed is listed with a state made
    /// from `now`, so that it is tried again under the same ID.
    func listing(at now: Date) -> Listing {
        let manager = FileManager.default
        var found = Listing()
        let names: [String]
        do { names = try manager.contentsOfDirectory(atPath: root.path) } catch {
            found.rootUnavailable = !Storage.isMissing(error)
            return found
        }
        for name in names {
            guard let id = UUID(uuidString: name), name == id.uuidString.lowercased() else {
                if name.hasPrefix(Self.unfinished) { found.leftovers.append(root.appending(path: name)) }
                continue
            }
            let directory = folder(id)
            do {
                let files = try manager.contentsOfDirectory(atPath: directory.path)
                guard files.contains(Self.reportFile) else {
                    found.leftovers.append(directory)
                    continue
                }
                if let state = try readState(in: directory) {
                    found.entries.append(Entry(id: id, state: state))
                } else {
                    let state = State(created: now, attempts: 0, notBefore: now,
                                      hasPayload: files.contains(Self.payloadFile))
                    found.entries.append(Entry(id: id, state: state, recovered: true))
                }
            } catch {
                if !Storage.isMissing(error) { found.unreadableEntries += 1 }
            }
        }
        found.entries.sort { ($0.state.created, $0.id.uuidString) < ($1.state.created, $1.id.uuidString) }
        return found
    }

    /// Removes what the listing found left over, and saves the states it had to make.
    func tidy(_ listing: Listing) {
        for leftover in listing.leftovers { try? Storage.remove(leftover) }
        for entry in listing.entries where entry.recovered { try? write(entry.state, to: folder(entry.id)) }
    }

    /// The state on disk; nil when it is missing or malformed. Throws when it is there but can't be read.
    private func readState(in directory: URL) throws -> State? {
        do {
            let bytes = try Data(contentsOf: directory.appending(path: Self.stateFile))
            return try Self.decoder.decode(State.self, from: bytes)
        } catch where Storage.isMissing(error) || error is DecodingError {
            return nil
        }
    }

    /// The report as it was queued. Throws when its JSON, or a payload it has, can't be read.
    func report(_ entry: Entry) throws -> PreparedReport {
        let directory = folder(entry.id)
        let json = try Data(contentsOf: directory.appending(path: Self.reportFile))
        let payload = entry.state.hasPayload ? try Data(contentsOf: directory.appending(path: Self.payloadFile)) : nil
        return PreparedReport(id: entry.id, json: json, payload: payload)
    }

    /// Counts a failed attempt and sets when the next may start: the server's `Retry-After` if it gave one,
    /// otherwise doubling from 30 seconds up to six hours. `unreachable` marks a failure to reach the server at
    /// all, whose backoff `makeDue` may cut short; a `Retry-After` is never cut short.
    /// - Returns: Whether the new state was saved.
    @discardableResult
    func recordFailure(_ entry: Entry, retryAfter: TimeInterval?, unreachable: Bool = false, now: Date) -> Bool {
        var state = entry.state
        state.attempts += 1
        state.retriesWhenReachable = unreachable && retryAfter == nil
        state.notBefore = now.addingTimeInterval(retryAfter.map { min(max($0, 1), 24 * 60 * 60) }
                                                 ?? Self.backoff(attempts: state.attempts))
        return (try? write(state, to: folder(entry.id))) != nil
    }

    /// Makes due the reports that are waiting only on their own backoff after failing to reach the server, so
    /// that a returning network or app tries them now. A report whose last attempt was less than `quiet` seconds
    /// ago is left, so that several triggers together don't send it again and again.
    func makeDue(now: Date, quiet: TimeInterval = 5) {
        for entry in listing(at: now).entries where entry.state.retriesWhenReachable && entry.state.notBefore > now {
            let lastAttempt = entry.state.notBefore.addingTimeInterval(-Self.backoff(attempts: entry.state.attempts))
            guard now.timeIntervalSince(lastAttempt) >= quiet else { continue }
            var state = entry.state
            state.notBefore = now
            state.retriesWhenReachable = false
            try? write(state, to: folder(entry.id))
        }
    }

    func remove(_ id: UUID) {
        try? Storage.remove(folder(id))
    }

    private struct Header: Decodable { let kind: ReportKind }

    /// The report's kind, which its JSON always has readable.
    static func kind(in json: Data) -> ReportKind? {
        (try? JSONDecoder().decode(Header.self, from: json))?.kind
    }

    /// Removes every telemetry report, and every report whose kind can't be read, along with writes that never
    /// finished. Throws the first failure, after trying the rest.
    func discardTelemetry() throws {
        let manager = FileManager.default
        let files: [URL]
        do { files = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) } catch where
            Storage.isMissing(error) { return }
        var firstFailure: (any Error)?
        for file in files {
            let name = file.lastPathComponent
            do {
                if name.hasPrefix(Self.unfinished) {
                    try Storage.remove(file)
                    continue
                }
                guard UUID(uuidString: name) != nil else { continue }
                let json = try Data(contentsOf: file.appending(path: Self.reportFile))
                switch Self.kind(in: json) {
                case .feedback, .crash: continue
                case .telemetry, nil: try Storage.remove(file)
                }
            } catch where Storage.isMissing(error) {
                // An entry without its JSON can't be sent, and the next pass removes it.
                continue
            } catch { firstFailure = firstFailure ?? error }
        }
        if let firstFailure { throw firstFailure }
    }

    /// 30 seconds after the first failure, doubling to six hours.
    static func backoff(attempts: Int) -> TimeInterval {
        min(30 * pow(2, Double(max(attempts - 1, 0))), 6 * 60 * 60)
    }

    private func folder(_ id: UUID) -> URL { root.appending(path: id.uuidString.lowercased()) }

    private func write(_ state: State, to directory: URL) throws {
        try Storage.write(try Self.encoder.encode(state), to: directory.appending(path: Self.stateFile))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
