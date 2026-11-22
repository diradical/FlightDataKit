// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import FlightData
import SwiftUI

@MainActor
extension View {
    /// Presents the feedback form as a sheet, with sections of your own, and queues its confirmed report using
    /// the environment's container.
    ///
    /// The form reads `draft`, `questions`, `contact` and `attachments` each time the sheet opens, and starts
    /// again from them after it sends or discards its feedback.
    ///
    /// - Parameters:
    ///   - isPresented: Whether the sheet is showing.
    ///   - draft: What the form starts with: a title, a description, values for fields and files.
    ///   - questions: Overrides the draft’s questions when supplied. An empty array clears them.
    ///   - contact: Whether the form asks how to reach the person.
    ///   - header: The line at the top of the form. Unless you give one, "Provide Feedback to" and the app's name.
    ///   - descriptionPrompt: What the empty description says. Unless you give one, it asks what the person
    ///     expected and what happened instead.
    ///   - fixedKeys: Keys of questions the person sees but can't change.
    ///   - attachments: Files the app offers. The person can look at each and leave out any that isn't required.
    ///   - extra: Sections of your own, placed above what is included.
    ///   - prepare: Prepare the feedback before submission. Changes are shown for confirmation. Throw to keep the
    ///     form open with an error. Returning to edit runs preparation again on the next submission.
    ///   - onQueued: Called once with the UUID after the report is queued locally. A preview simulates success.
    public func feedbackSheet<Extra: View>(
        isPresented: Binding<Bool>,
        draft: Feedback = Feedback(),
        asking questions: [ReportField]? = nil,
        contact: Feedback.Contact = .optional,
        header: LocalizedStringResource? = nil,
        descriptionPrompt: LocalizedStringResource? = nil,
        fixedKeys: Set<String> = [],
        attachments: [FeedbackAttachment] = [],
        @ViewBuilder extra: () -> Extra,
        prepare: (@MainActor @Sendable (inout Feedback) async throws -> Void)? = nil,
        onQueued: (@MainActor @Sendable (UUID) -> Void)? = nil
    ) -> some View {
        FeedbackDraft.assertValid(questions: questions ?? draft.questions)
        return modifier(FeedbackSheet(isPresented: isPresented, draft: draft, questions: questions, contact: contact,
                                      header: header, descriptionPrompt: descriptionPrompt, fixedKeys: fixedKeys,
                                      attachments: attachments, extra: extra(), prepare: prepare, onQueued: onQueued))
    }

    /// Presents the feedback form as a sheet and queues its confirmed report with the environment's container.
    ///
    /// The form reads `draft`, `questions`, `contact` and `attachments` each time the sheet opens, and starts
    /// again from them after it sends or discards its feedback.
    ///
    /// - Parameters:
    ///   - isPresented: Whether the sheet is showing.
    ///   - draft: What the form starts with: a title, a description, values for fields and files.
    ///   - questions: Overrides the draft’s questions when supplied. An empty array clears them.
    ///   - contact: Whether the form asks how to reach the person.
    ///   - header: The line at the top of the form. Unless you give one, "Provide Feedback to" and the app's name.
    ///   - descriptionPrompt: What the empty description says. Unless you give one, it asks what the person
    ///     expected and what happened instead.
    ///   - fixedKeys: Keys of questions the person sees but can't change.
    ///   - attachments: Files the app offers. The person can look at each and leave out any that isn't required.
    ///   - prepare: Prepare the feedback before submission. Changes are shown for confirmation. Throw to keep the
    ///     form open with an error. Returning to edit runs preparation again on the next submission.
    ///   - onQueued: Called once with the UUID after the report is queued locally. A preview simulates success.
    public func feedbackSheet(
        isPresented: Binding<Bool>,
        draft: Feedback = Feedback(),
        asking questions: [ReportField]? = nil,
        contact: Feedback.Contact = .optional,
        header: LocalizedStringResource? = nil,
        descriptionPrompt: LocalizedStringResource? = nil,
        fixedKeys: Set<String> = [],
        attachments: [FeedbackAttachment] = [],
        prepare: (@MainActor @Sendable (inout Feedback) async throws -> Void)? = nil,
        onQueued: (@MainActor @Sendable (UUID) -> Void)? = nil
    ) -> some View {
        feedbackSheet(isPresented: isPresented, draft: draft, asking: questions, contact: contact, header: header,
                      descriptionPrompt: descriptionPrompt, fixedKeys: fixedKeys, attachments: attachments,
                      extra: { EmptyView() }, prepare: prepare, onQueued: onQueued)
    }
}

/// Presents the form, handing it the presenting view's context: a sheet is a separate presentation, which
/// doesn't always inherit the environment.
private struct FeedbackSheet<Extra: View>: ViewModifier {
    @Binding var isPresented: Bool
    let draft: Feedback
    let questions: [ReportField]?
    let contact: Feedback.Contact
    let header: LocalizedStringResource?
    let descriptionPrompt: LocalizedStringResource?
    let fixedKeys: Set<String>
    let attachments: [FeedbackAttachment]
    let extra: Extra
    let prepare: (@MainActor @Sendable (inout Feedback) async throws -> Void)?
    let onQueued: (@MainActor @Sendable (UUID) -> Void)?
    @Environment(\.flightDataContainer) private var container

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            FeedbackForm(draft: draft, asking: questions, contact: contact, header: header,
                         descriptionPrompt: descriptionPrompt, fixedKeys: fixedKeys, attachments: attachments,
                         extra: { extra }, prepare: prepare, onQueued: onQueued)
                .environment(\.flightDataContainer, container)
        }
    }
}
