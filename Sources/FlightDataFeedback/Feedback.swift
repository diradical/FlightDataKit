// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import FlightData
import Foundation

/// What a person has to say about the app: a title, a description, how to reach them, the answers to the app's
/// own questions, and the files that go with it. The form fills one in; an app can also make one itself. It is
/// saved explicitly: inserted, then submitted.
public struct Feedback: FlightDataReport, Codable, Equatable {
    /// Whether the form asks how to reach the person.
    public enum Contact: Hashable, Sendable {
        /// The form doesn't ask, and the feedback is sent without contact details.
        case none
        /// The form asks, and the person can leave it blank.
        case optional
        /// The form can't be sent until the person says how to reach them.
        case required
    }

    /// One line saying what it is about. Required, at most 200 characters.
    public var title: String
    /// The description. Required, at most 5,000 characters.
    public var body: String
    /// How to reach the person, if they gave it.
    public var contact: String?
    /// The app's own values by key, such as `"document": "Untitled 3"` or `"copies": 2`. At most 50.
    public var fields: [String: ReportValue]
    /// The files sent with the feedback, such as a screenshot or the document the person was working on. At most
    /// 1,000 files and 10 MB together, each with a distinct name.
    public var files: [ReportFile]
    /// The questions and values the fields belong to. What each says of its field travels with the feedback; a
    /// field with none is shown by its key.
    public var questions: [ReportField]

    /// Empty feedback, for the form to fill in.
    public init() {
        self.init(title: "")
    }

    /// - Parameters:
    ///   - title: One line saying what it is about.
    ///   - body: The description.
    ///   - contact: How to reach the person.
    ///   - fields: The app's own values by key.
    ///   - files: The files sent with the feedback.
    ///   - questions: The questions and values the fields belong to.
    public init(title: String, body: String = "", contact: String? = nil, fields: [String: ReportValue] = [:],
                files: [ReportFile] = [], questions: [ReportField] = []) {
        self.title = title
        self.body = body
        self.contact = contact
        self.fields = fields
        self.files = files
        self.questions = questions
    }

    /// The channel feedback is sent on.
    public static var name: String { "Feedback" }
    /// Feedback is a report a person writes.
    public static var kind: ReportKind { .feedback }

    /// Checks the feedback: a description, a valid set of questions with an allowed answer to each, contact
    /// details when they are required, and the format's own bounds.
    public func validate(contact requirement: Contact = .optional) throws {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReportValidationError(.required, "A description is required.", field: "body")
        }
        if requirement == .required, (contact ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ReportValidationError(.required, "Contact details are required.", field: "contact")
        }
        try ReportField.validate(questions)
        for question in questions { try question.validate(value: fields[question.key]) }
        try ReportContent(title: title, body: body, contact: contact, fields: fields,
                          fieldDescriptions: fieldDescriptions, files: files).validate()
    }

    /// What is sealed and sent, once `validate()` finds nothing wrong: the text, the fields with what the
    /// questions say of them, and the files.
    public func content() throws -> ReportContent {
        try validate()
        return ReportContent(title: title, body: body, contact: contact, fields: fields,
                             fieldDescriptions: fieldDescriptions, files: files)
    }

    /// What the questions say of the fields that have values, in the questions' order.
    var fieldDescriptions: [FieldDescription] {
        questions.compactMap { question in
            guard let value = fields[question.key] else { return nil }
            var option: String?
            if case .choice(let options) = question.kind, case .text(let chosen) = value {
                option = options.first { $0.value == chosen }?.label
            }
            return FieldDescription(key: question.key, label: question.label, kind: question.kind.fieldKind,
                                    option: option)
        }
    }
}
