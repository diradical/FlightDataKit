// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import FlightData
import Foundation
import Observation

/// Owns the report awaiting confirmation or retry until the person chooses to edit again.
@MainActor @Observable
final class FeedbackSubmission {
    private(set) var review: Feedback?
    private(set) var busy = false

    /// - Parameter review: A report already awaiting confirmation, as for a preview.
    init(review: Feedback? = nil) {
        self.review = review
    }

    func edit() { review = nil }

    func reset() {
        review = nil
        busy = false
    }

    func removeFile(named name: String) { review?.files.removeAll { $0.name == name } }

    /// Returns true once the form can close. A queued submission stays busy until the form resets.
    func send(confirming: Bool, source: () throws -> Feedback, excluding files: Set<String>, contact: Feedback.Contact,
              prepare: (@MainActor (inout Feedback) async throws -> Void)?,
              queue: (Feedback) async throws -> UUID, onQueued: (@MainActor (UUID) -> Void)?) async throws -> Bool {
        guard !busy, confirming == (review != nil) else { return false }
        busy = true
        var queued = false
        defer { if !queued { busy = false } }

        let report: Feedback
        if let review {
            report = review
        } else {
            let draft = try source()
            var candidate = draft
            if let prepare { try await prepare(&candidate) }
            candidate.files.removeAll { files.contains($0.name) }
            if contact == .none { candidate.contact = nil }
            if candidate != draft {
                review = candidate
                return false
            }
            report = candidate
        }
        try report.validate(contact: contact)
        do {
            let id = try await queue(report)
            queued = true
            onQueued?(id)
            return true
        } catch {
            review = report
            throw error
        }
    }
}
