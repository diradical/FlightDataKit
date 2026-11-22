// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation

/// What a report holds once it is ready to be sealed: its text, the app's own values and what the app says of
/// them, and the files that go with it. Every report type turns itself into one of these.
public struct ReportContent: Sendable {
    /// One line saying what the report is. Required, at most 200 characters.
    public var title: String
    /// The longer text: what happened, in the person's words. At most 5,000 characters.
    public var body: String
    /// How to reach the person, if they gave it. At most 254 characters.
    public var contact: String?
    /// The app's own values by key. At most 50.
    public var fields: [String: ReportValue]
    /// What the app says of those fields, in the order to show them: one for each field it describes. A field
    /// with no description is shown by its key.
    public var fieldDescriptions: [FieldDescription]
    /// The files that go with the report: at most 1,000, and 10 MB together.
    public var files: [ReportFile]
    /// The build the report is about, when it isn't the one running: a crash is about the build that crashed,
    /// which an update may have replaced by the time it is sent. Nil for the running app. Unlike the rest, the
    /// server can read this.
    public var app: AppInfo?

    /// Content with a title, and whatever else the report has.
    public init(title: String, body: String = "", contact: String? = nil, fields: [String: ReportValue] = [:],
                fieldDescriptions: [FieldDescription] = [], files: [ReportFile] = [], app: AppInfo? = nil) {
        self.title = title
        self.body = body
        self.contact = contact
        self.fields = fields
        self.fieldDescriptions = fieldDescriptions
        self.files = files
        self.app = app
    }

    /// Checks the content against the format's bounds. Nothing is cut to make it fit.
    ///
    /// - Throws: A ``ReportValidationError`` for the first thing that doesn't fit.
    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReportValidationError(.required, "A title of 1–\(ReportLimits.titleLength) characters is required.",
                                        field: "title")
        }
        guard title.unicodeScalars.count <= ReportLimits.titleLength else {
            throw ReportValidationError(.tooLong, "A title can have at most \(ReportLimits.titleLength) characters.",
                                        field: "title")
        }
        guard body.unicodeScalars.count <= ReportLimits.descriptionLength else {
            throw ReportValidationError(.tooLong, "The description must have at most "
                                        + "\(ReportLimits.count(ReportLimits.descriptionLength)) characters.",
                                        field: "body")
        }
        guard (contact?.unicodeScalars.count ?? 0) <= ReportLimits.contactLength else {
            throw ReportValidationError(.tooLong, "Contact details must have at most \(ReportLimits.contactLength) "
                                        + "characters.", field: "contact")
        }
        try ReportLimits.validateFields(fields)
        try validateFieldDescriptions()
        // The title, description, contact details, fields and what is said of them are sealed together and share
        // one bound.
        let text = ReportText(title: title, body: body, contact: contact, fields: fields,
                              fieldDescriptions: fieldDescriptions)
        guard try text.encoded().count <= ReportLimits.textBytes else {
            throw ReportValidationError(.limitExceeded,
                                        "The report’s text is too long to send. Shorten the description.")
        }
        try validateFiles()
    }

    /// At most one description for each field, each for a field the report has, with a label and an option name
    /// of a reasonable length, and a kind the format defines.
    private func validateFieldDescriptions() throws {
        var described: Set<String> = []
        for description in fieldDescriptions {
            let key = description.key
            guard fields[key] != nil else {
                throw ReportValidationError(.invalidDescription,
                                            "‘\(key)’ is described but the report has no such field.", field: key)
            }
            guard described.insert(key).inserted else {
                throw ReportValidationError(.duplicate, "‘\(key)’ is described more than once.", field: key)
            }
            let label = description.label
            guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  label.unicodeScalars.count <= ReportLimits.fieldLabelLength,
                  (description.option?.unicodeScalars.count ?? 0) <= ReportLimits.fieldLabelLength else {
                throw ReportValidationError(.invalidDescription, "‘\(key)’ needs a label, and a chosen option’s "
                                            + "name, of at most \(ReportLimits.fieldLabelLength) characters.",
                                            field: key)
            }
            if case .unknown(let kind) = description.kind {
                throw ReportValidationError(.invalidDescription, "‘\(key)’ has a kind the format doesn’t define: "
                                            + "\(kind).", field: key)
            }
        }
    }

    private func validateFiles() throws {
        guard files.count <= ReportLimits.attachmentCount else {
            throw ReportValidationError(.limitExceeded, "A report can include at most "
                                        + "\(ReportLimits.count(ReportLimits.attachmentCount)) files.", field: "files")
        }
        var names: Set<String> = []
        var bytes = 0
        for file in files {
            try ReportLimits.validateFileName(file.name, used: &names)
            guard file.data.count <= ReportLimits.attachmentBytes - bytes else {
                let limit = ReportLimits.megabytes(ReportLimits.attachmentBytes)
                throw ReportValidationError(.limitExceeded, "Attachments must total at most \(limit).", field: "files")
            }
            bytes += file.data.count
        }
    }
}
