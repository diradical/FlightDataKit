// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation

/// The periodic reports being gathered: one open window per type, kept in memory, and saved a moment after it
/// changes, and at once when the app goes to the background or quits, so that recording an event costs no disk
/// work of its own.
///
/// Each window is one file, named by its ID, with the type's channel, its kind, when it started and the gathered
/// report as JSON. A window whose period has ended is closed: it waits, still on disk, until the container has
/// sealed and queued it, and then its file is removed. The report takes the window's ID, so a window queued again
/// after the app was stopped halfway is still one report to the server.
///
/// Calls may come from any thread; a lock orders them.
final class PeriodicWindows: @unchecked Sendable {
    struct Window: Codable, Equatable, Sendable {
        let id: UUID
        /// The type's channel.
        let name: String
        let kind: ReportKind
        let started: Date
        /// The gathered report, as JSON.
        var report: Data
    }

    /// What recording an event did.
    enum Change: Equatable {
        /// It started a window.
        case opened
        /// It joined the open window.
        case merged
        /// It closed the open window, whose period had ended or whose report this version can't read, and started
        /// another.
        case closedAndOpened
        /// Telemetry is off, or what was gathered before it was turned off is still being erased.
        case refused
        /// The window with this event in it can't be written as JSON.
        case unencodable
    }

    let directory: URL
    private let saveDelay: Duration
    private let lock = NSLock()
    private var loaded = false
    private var open: [String: Window] = [:]
    private var closed: [UUID: Window] = [:]
    private var unsaved: Set<UUID> = []
    /// Windows that were discarded but whose files couldn't be removed yet.
    private var stale: Set<UUID> = []
    private var saveTask: Task<Void, Never>?

    /// - Parameters:
    ///   - directory: Where the windows are kept.
    ///   - saveDelay: How long after a change the windows are saved. Zero saves at once.
    init(directory: URL, saveDelay: Duration) {
        self.directory = directory
        self.saveDelay = saveDelay
    }

    deinit {
        saveTask?.cancel()
        saveNow()
    }

    /// Folds `report` into the open window of its type, or starts one.
    func record<Report: PeriodicFlightDataReport>(_ report: Report, name: String, kind: ReportKind,
                                                  period: TimeInterval, at time: Date,
                                                  consent: TelemetryConsent) -> Change {
        lock.withLock {
            guard kind != .telemetry || consent.acceptsTelemetry else { return .refused }
            loadIfNeeded()
            var change = Change.opened
            var continued: Window?
            var merged = report
            if let window = open[name] {
                change = .closedAndOpened
                if window.kind == kind, time < window.started.addingTimeInterval(period),
                   var earlier = try? JSONDecoder().decode(Report.self, from: window.report) {
                    earlier.merge(report)
                    merged = earlier
                    continued = window
                    change = .merged
                }
            }
            guard let encoded = try? JSONEncoder().encode(merged) else { return .unencodable }
            if change == .closedAndOpened, let ended = open[name] { closed[ended.id] = ended }
            let window = Window(id: continued?.id ?? UUID(), name: name, kind: kind,
                                started: continued?.started ?? time, report: encoded)
            open[name] = window
            changed(window.id)
            return change
        }
    }

    /// Closes the open windows whose period has ended by `now`, and returns every closed window, oldest first.
    /// `periods` holds the period of each periodic type in the schema; a window of any other type is closed.
    func closeDue(at now: Date, periods: [String: TimeInterval]) -> [Window] {
        lock.withLock {
            loadIfNeeded()
            for (name, window) in open {
                if let period = periods[name], now < window.started.addingTimeInterval(period) { continue }
                open[name] = nil
                closed[window.id] = window
            }
            return closed.values.sorted { ($0.started, $0.id.uuidString) < ($1.started, $1.id.uuidString) }
        }
    }

    /// When the first open window's period ends.
    func nextDeadline(periods: [String: TimeInterval]) -> Date? {
        lock.withLock {
            open.values.compactMap { window in
                periods[window.name].map { window.started.addingTimeInterval($0) }
            }.min()
        }
    }

    /// Forgets a closed window and removes its file: it has been queued, or never can be.
    func remove(_ id: UUID) {
        lock.withLock {
            closed[id] = nil
            discard(id)
        }
    }

    /// Discards every telemetry window, in memory at once and then on disk.
    ///
    /// - Throws: When the windows on disk can't be read or removed. Files left behind are removed on a later save.
    func discardTelemetry() throws {
        try lock.withLock {
            loadIfNeeded()
            guard loaded else { throw CocoaError(.fileReadNoPermission) }
            for (name, window) in open where window.kind == .telemetry {
                open[name] = nil
                discard(window.id)
            }
            for (id, window) in closed where window.kind == .telemetry {
                closed[id] = nil
                discard(id)
            }
            guard stale.isEmpty else { throw CocoaError(.fileWriteNoPermission) }
        }
    }

    /// Saves the windows that changed since they were last saved.
    func save() {
        lock.withLock { saveNow() }
    }

    // MARK: - Under the lock

    private func file(_ id: UUID) -> URL { directory.appending(path: id.uuidString.lowercased() + ".window") }

    private func changed(_ id: UUID) {
        unsaved.insert(id)
        if saveDelay == .zero {
            saveNow()
        } else if saveTask == nil {
            let delay = saveDelay
            saveTask = Task { [weak self] in
                guard (try? await Task.sleep(for: delay)) != nil else { return }
                self?.save()
            }
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        removeStale()
        guard !unsaved.isEmpty else { return }
        do {
            try Storage.makeDirectory(directory.deletingLastPathComponent())
            try Storage.makeDirectory(directory)
        } catch {
            Log.periodic.log(.error, "Periodic reports couldn’t be saved: \(error.localizedDescription)")
            return
        }
        for id in unsaved {
            guard let window = open.values.first(where: { $0.id == id }) ?? closed[id] else {
                unsaved.remove(id)
                continue
            }
            do {
                try Storage.write(try JSONEncoder().encode(window), to: file(id))
                unsaved.remove(id)
            } catch {
                Log.periodic.log(.error, "Periodic report \(id) couldn’t be saved: "
                                         + "\(error.localizedDescription)")
            }
        }
    }

    /// Forgets a window that is no longer in memory, and removes its file.
    private func discard(_ id: UUID) {
        unsaved.remove(id)
        stale.insert(id)
        removeStale()
    }

    private func removeStale() {
        for id in stale {
            do {
                try Storage.remove(file(id))
                stale.remove(id)
            } catch {
                Log.periodic.log(.error, "Periodic report \(id) couldn’t be removed: "
                                         + "\(error.localizedDescription)")
            }
        }
    }

    /// Reads the windows an earlier run saved, once. Windows already in memory are newer, so a saved window of a type
    /// that has one in memory is closed. A file that can't be decoded is removed; a directory that can't be read
    /// is tried again on the next call.
    private func loadIfNeeded() {
        guard !loaded else { return }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            loaded = Storage.isMissing(error)
            if !loaded {
                Log.periodic.log(.error, "Periodic reports couldn’t be read: \(error.localizedDescription)")
            }
            return
        }
        loaded = true
        var saved: [Window] = []
        for file in files where file.pathExtension == "window" {
            do {
                saved.append(try JSONDecoder().decode(Window.self, from: Data(contentsOf: file)))
            } catch where error is DecodingError {
                Log.periodic.log(.error, "Removed an unreadable periodic report: \(file.lastPathComponent)")
                try? Storage.remove(file)
            } catch {
                loaded = false
            }
        }
        for window in saved.sorted(by: { $0.started > $1.started }) {
            guard open.values.allSatisfy({ $0.id != window.id }), closed[window.id] == nil else { continue }
            if open[window.name] == nil { open[window.name] = window } else { closed[window.id] = window }
        }
    }
}
