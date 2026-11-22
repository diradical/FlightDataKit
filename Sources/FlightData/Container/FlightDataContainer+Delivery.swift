// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import FlightDataFormat
import Foundation

extension FlightDataContainer {
    /// The shortest wait before a pass the container schedules itself: a report due now that wasn't sent, because
    /// its state couldn't be saved or the app ran out of background time, isn't tried again at once.
    static let shortestRetryDelay: TimeInterval = 30

    /// Seals and queues the periodic reports whose period has ended, sends every queued report that is due, drops
    /// those unsent after 30 days, and schedules the next attempt while any remain.
    ///
    /// Nothing needs to call it: a container does when it is made, when a report is submitted or a period ends,
    /// when the app comes back to the foreground and when the network returns. It returns once no pass is
    /// running or asked for, so a call made during a pass waits for one that starts after it. On iOS a pass has
    /// the time the system allows once the app is in the background; if that runs out, the upload in flight is
    /// cancelled and its report stays queued.
    public func deliverPending() async {
        requestPass()
        while let running = delivering { await running.value }
    }

    /// Asks for a pass without waiting for it. Asking again while one is running asks for one more after it.
    func requestPass() {
        guard setup?.keeps == true else { return }
        passRequested = true
        guard delivering == nil else { return }
        delivering = Task {
            await BackgroundTime.run { await self.runPasses() }
            self.delivering = nil
            // Asked for after the last pass looked.
            if self.passRequested { self.requestPass() }
        }
    }

    private func runPasses() async {
        while passRequested {
            passRequested = false
            await pass()
            // Out of background time: what is left is tried again when the pass's retry comes due.
            if Task.isCancelled { passRequested = false }
        }
    }

    /// The app became active or the network came back. Reports that were waiting only on a backoff after failing
    /// to reach the server are due now; those the server asked to wait are not.
    func retryNow() async {
        makeDueRequested = true
        await deliverPending()
    }

    private func pass() async {
        guard let setup, setup.keeps else { return }
        passCount += 1
        retryTask?.cancel()
        retryTask = nil
        retryAt = nil
        let start = now()
        if makeDueRequested {
            makeDueRequested = false
            setup.queue.makeDue(now: start)
        }
        var storageProblem = false
        if consent.needsErasure {
            do { try eraseTelemetry() } catch { storageProblem = true }
        }
        if !flushPeriodic(setup, at: start) { storageProblem = true }
        let listing = setup.queue.listing(at: now())
        setup.queue.tidy(listing)
        var deferred: Set<UUID> = []
        for entry in listing.entries {
            guard !Task.isCancelled else { break }
            if await !send(entry, setup) { deferred.insert(entry.id) }
        }
        scheduleRetry(setup, deferring: deferred, storageProblem: storageProblem || listing.hasStorageProblem)
    }

    /// Sends one report if it is due, and keeps, reschedules or removes it by what happened.
    /// - Returns: False when the report couldn't be read or its new state couldn't be saved, or it waits on
    ///   erasing telemetry: then it isn't counted as due, and the next pass is backed off instead.
    private func send(_ entry: ReportQueue.Entry, _ setup: Setup) async -> Bool {
        let queue = setup.queue
        let current = now()
        let id = entry.id
        if current.timeIntervalSince(entry.state.created) > ReportQueue.maximumAge {
            Log.delivery.log(.default, "Report \(id) was deleted: it couldn’t be sent within 30 days.")
            queue.remove(id)
            return true
        }
        guard entry.state.notBefore <= current else { return true }
        guard let report = try? queue.report(entry) else { return false }
        let kind = ReportQueue.kind(in: report.json) ?? .telemetry
        guard let permit = consent.permit(for: kind) else {
            Log.delivery.log(.default, "Report \(id) was deleted: telemetry is turned off.")
            queue.remove(id)
            return true
        }
        guard kind != .telemetry || !consent.needsErasure else { return false }
        guard let installID = try? setup.installIDs.installID() else {
            return queue.recordFailure(entry, retryAfter: nil, now: current)
        }
        let proof: ReportProof?
        switch await setup.prover.proof(for: report, now: current) {
        case .proven(let made): proof = made
        case .unproven: proof = nil
        case .wait(let after):
            return Task.isCancelled || queue.recordFailure(entry, retryAfter: after, now: now())
        case .unreachable:
            return Task.isCancelled || queue.recordFailure(entry, retryAfter: nil, unreachable: true, now: now())
        }
        guard !Task.isCancelled, consent.permit(for: kind) == permit else { return true }
        let outcome = await upload(report, with: setup.sender, installID: installID, proof: proof, kind: kind)
        // Telemetry turned off meanwhile was erased, this report with it.
        guard consent.permit(for: kind) == permit else { return true }
        switch outcome {
        case .delivered(_, let unknownKey):
            // Taken, but the server no longer knows the key the proof was made with, so another is enrolled.
            if unknownKey { setup.prover.forget(now: now()) }
            queue.remove(id)
        case .drop(let status):
            Log.delivery.log(.error, "Report \(id) was deleted: the server refused it with status "
                                     + "\(status).")
            queue.remove(id)
        case .retry(let after):
            return queue.recordFailure(entry, retryAfter: after, now: now())
        case .unreachable:
            // Cancelled when the app ran out of background time: not an attempt, so the report stays as it was.
            return Task.isCancelled || queue.recordFailure(entry, retryAfter: nil, unreachable: true, now: now())
        case .proofRefused(let unknownKey):
            // Tried again with another challenge and signature, and with another key when this one isn't known.
            if unknownKey { setup.prover.forget(now: now()) }
            return queue.recordFailure(entry, retryAfter: nil, now: now())
        case .proofRequired:
            // A copy that can prove itself tries again once it has enrolled. One that never can drops the report.
            guard setup.prover.isSupported else {
                Log.delivery.log(.error, "Report \(id) was deleted: the app takes only proven reports, "
                                         + "and this device can’t prove itself with App Attest.")
                queue.remove(id)
                return true
            }
            return queue.recordFailure(entry, retryAfter: nil, now: now())
        }
        return true
    }

    /// Sends a report. A telemetry upload is kept where turning telemetry off can cancel it.
    private func upload(_ report: PreparedReport, with sender: ReportSender, installID: String, proof: ReportProof?,
                        kind: ReportKind) async -> DeliveryOutcome {
        guard kind == .telemetry else { return await sender.send(report, installID: installID, proof: proof) }
        let task = Task {
            guard !Task.isCancelled else { return DeliveryOutcome.unreachable }
            return await sender.send(report, installID: installID, proof: proof)
        }
        telemetryUpload = task
        defer { telemetryUpload = nil }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Schedules the next pass for when the first report not deferred is due. When a report or a folder couldn't be
    /// read or written, the next pass is also backed off, from 30 seconds to six hours, until one passes cleanly.
    private func scheduleRetry(_ setup: Setup, deferring deferred: Set<UUID>, storageProblem: Bool) {
        let current = now()
        let listing = setup.queue.listing(at: current)
        var next = listing.nextAttempt(excluding: deferred)
        if storageProblem || listing.hasStorageProblem || !deferred.isEmpty {
            storageFailures += 1
            let backedOff = current.addingTimeInterval(ReportQueue.backoff(attempts: storageFailures))
            next = min(next ?? backedOff, backedOff)
        } else {
            storageFailures = 0
        }
        guard let next else { return }
        let seconds = max(next.timeIntervalSince(current), Self.shortestRetryDelay)
        retryAt = current.addingTimeInterval(seconds)
        retryTask = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(seconds))) != nil else { return }
            await self?.retryFired()
        }
    }

    private func retryFired() {
        retryTask = nil
        retryAt = nil
        requestPass()
    }

    // MARK: - Periodic reports

    /// An event was recorded. One that closed a window has it sealed now; one that opened a window may bring the
    /// next deadline nearer.
    func periodicChanged(closed: Bool) {
        guard let setup, let windows = setup.windows else { return }
        if closed {
            requestPass()
        } else {
            wakePeriodic(at: windows.nextDeadline(periods: setup.periods))
        }
    }

    /// Seals and queues each window whose period has ended, and wakes for the next deadline.
    /// - Returns: False when a window couldn't be queued, which is tried again later.
    private func flushPeriodic(_ setup: Setup, at time: Date) -> Bool {
        guard let windows = setup.windows else { return true }
        let periods = setup.periods
        var queuedAll = true
        for window in windows.closeDue(at: time, periods: periods) {
            // Telemetry gathered before it was turned off waits until it has been erased.
            if window.kind == .telemetry, !consent.acceptsTelemetry { continue }
            guard let route = setup.routesByName[window.name], let content = route.periodicContent else {
                // An update removed the type. Its window is kept a while, in case another brings the type back.
                if time.timeIntervalSince(window.started) >= ReportQueue.maximumAge {
                    Log.periodic.log(.default, "Periodic report \(window.id) was deleted: its type left the "
                                               + "schema.")
                    windows.remove(window.id)
                }
                continue
            }
            // Queued before the app stopped, and the window not yet removed.
            guard !setup.queue.contains(window.id) else {
                windows.remove(window.id)
                continue
            }
            let prepared: PreparedReport
            do {
                prepared = try PreparedReport.make(try content(window.report), kind: window.kind,
                                                   channel: window.name, app: app, test: setup.test,
                                                   recipient: route.recipient, id: window.id)
            } catch {
                Log.periodic.log(.error, "Periodic report \(window.id) was deleted: it couldn’t be "
                                         + "prepared (\(Self.reason(error))).")
                windows.remove(window.id)
                continue
            }
            do {
                try setup.queue.enqueue(prepared, now: time)
                windows.remove(window.id)
            } catch {
                Log.periodic.log(.error, "Periodic report \(window.id) couldn’t be queued: "
                                         + "\(error.localizedDescription)")
                queuedAll = false
            }
        }
        wakePeriodic(at: windows.nextDeadline(periods: periods))
        return queuedAll
    }

    /// Why a report couldn't be prepared, without anything it says: the validation reason and field key, or the
    /// error's type.
    private static func reason(_ error: any Error) -> String {
        if let invalid = error as? ReportValidationError { return "\(invalid.reason.rawValue) \(invalid.field ?? "")" }
        return String(describing: type(of: error))
    }

    /// Asks for a pass at `date`. Long waits are rechecked daily, in case the device's clock changes.
    private func wakePeriodic(at date: Date?) {
        guard date != periodicWake else { return }
        periodicTask?.cancel()
        periodicTask = nil
        periodicWake = date
        guard let date else { return }
        let delay = min(max(date.timeIntervalSince(now()), 0), 86_400)
        periodicTask = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(delay))) != nil else { return }
            await self?.periodicTimerFired(at: date)
        }
    }

    private func periodicTimerFired(at date: Date) {
        guard periodicWake == date else { return }
        periodicTask = nil
        periodicWake = nil
        requestPass()
    }
}
