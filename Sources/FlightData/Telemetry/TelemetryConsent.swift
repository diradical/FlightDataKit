// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation

/// Whether the person allows telemetry, remembered in the kit's directory, and whether what was gathered before
/// they turned it off is still to be erased.
///
/// Two empty files say so: one while telemetry is off, and one from the moment it is turned off until everything
/// gathered before has been erased, so that an erasure cut short by the app quitting is finished on the next
/// launch. Each change of mind also starts a new revision, so that work begun under an earlier one can tell that
/// it no longer counts.
final class TelemetryConsent: @unchecked Sendable {
    private static let disabledName = "telemetry-disabled"
    private static let erasureName = "telemetry-erasure-pending"

    private let lock = NSLock()
    /// Where the choice is kept; nil to keep it only in memory.
    private let directory: URL?
    private var enabled: Bool
    private var erasing: Bool
    private var revision: UInt64 = 0

    /// Reads the remembered choice, and applies `choice` over it when there is one.
    init(directory: URL?, choice: Bool?) {
        self.directory = directory
        enabled = !(directory.map { Storage.exists($0.appending(path: Self.disabledName)) } ?? false)
        erasing = directory.map { Storage.exists($0.appending(path: Self.erasureName)) } ?? false
        if let choice { _ = setEnabled(choice) }
    }

    /// Whether the person allows telemetry.
    var isEnabled: Bool { lock.withLock { enabled } }

    /// Whether telemetry gathered before it was turned off is still to be erased.
    var needsErasure: Bool { lock.withLock { erasing } }

    /// Whether new telemetry can be taken now: the person allows it, and nothing from before is left to erase.
    var acceptsTelemetry: Bool { lock.withLock { enabled && !erasing } }

    /// The revision under which a report of `kind` may be sent; nil for telemetry while it is off. Other kinds are
    /// always allowed.
    func permit(for kind: ReportKind) -> UInt64? {
        guard kind == .telemetry else { return 0 }
        return lock.withLock { enabled ? revision : nil }
    }

    /// Remembers the person's choice. Turning telemetry off also marks what was gathered as to be erased, before
    /// anything is erased. Returns whether the choice changed.
    func setEnabled(_ newValue: Bool) -> Bool {
        lock.withLock {
            guard newValue != enabled else { return false }
            enabled = newValue
            revision &+= 1
            if !newValue { erasing = true }
            persist()
            return true
        }
    }

    /// Everything gathered before telemetry was turned off is gone.
    func erasureFinished() {
        lock.withLock {
            guard erasing else { return }
            erasing = false
            persist()
        }
    }

    /// Writes the two files, under the lock. Without them the choice still holds for this run; the kit logs it.
    private func persist() {
        guard let directory else { return }
        do {
            try Self.mark(directory.appending(path: Self.disabledName), present: !enabled)
            try Self.mark(directory.appending(path: Self.erasureName), present: erasing)
        } catch {
            Log.telemetry.log(.error, "The telemetry choice couldn’t be saved: \(error.localizedDescription)")
        }
    }

    /// Writes the empty file `marker`, or removes it.
    private static func mark(_ marker: URL, present: Bool) throws {
        guard present else { return try Storage.remove(marker) }
        guard !Storage.exists(marker) else { return }
        try Storage.makeDirectory(marker.deletingLastPathComponent())
        try Storage.write(Data(), to: marker)
    }
}
