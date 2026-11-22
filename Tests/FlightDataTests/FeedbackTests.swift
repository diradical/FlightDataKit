// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation
import Testing
@testable import FlightData
@testable import FlightDataFeedback
@testable import FlightDataFormat

private let questions = [
    ReportField(key: "area", label: "Area", kind: .choice([.init("canvas", label: "Canvas"),
                                                           .init("export", label: "Export")]), required: true),
    ReportField(key: "copies", label: "Copies", kind: .integer),
    ReportField(key: "zoom", label: "Zoom", kind: .number),
    ReportField(key: "beta", label: "In the beta", kind: .boolean),
    ReportField(key: "document", label: "Document", asked: false),
]

@Test func whatAQuestionSaysOfItsFieldTravelsSealedWithTheFeedback() throws {
    let keys = Keys()
    let feedback = Feedback(title: "t", body: "b", contact: "me@example.test",
                            fields: ["document": "Untitled 3", "area": "export", "copies": 2, "undeclared": "kept"],
                            questions: questions)
    let report = try PreparedReport.make(try feedback.content(), kind: Feedback.kind, channel: Feedback.name,
                                         app: testApp,
                                         test: true, recipient: keys.recipient)
    let json = try #require(JSONSerialization.jsonObject(with: report.json) as? [String: Any])
    #expect(json["kind"] as? String == "feedback" && json["channel"] as? String == "Feedback")
    let text = try openText(json, keys: keys)
    // In the questions' order, only the fields the feedback has, and a choice with what its option is called.
    #expect(text.fieldDescriptions == [FieldDescription(key: "area", label: "Area", kind: .choice, option: "Export"),
                                       FieldDescription(key: "copies", label: "Copies", kind: .integer),
                                       FieldDescription(key: "document", label: "Document", kind: .text)])
    #expect(text.fields == ["document": "Untitled 3", "area": "export", "copies": 2, "undeclared": "kept"])
    #expect(String(decoding: try text.encoded(), as: UTF8.self)
        .contains(#""schema":[{"key":"area","kind":"choice","label":"Area","option":"Export"},"#))
}

@Test func feedbackIsCheckedAgainstItsQuestions() throws {
    let valid = Feedback(title: "t", body: "b", contact: "me@example.test",
                         fields: ["area": "canvas", "zoom": 1.5, "beta": true], questions: questions)
    try valid.validate(contact: .required)
    var feedback = valid
    feedback.fields["area"] = nil
    #expect(throws: ReportValidationError(.required, "‘Area’ is required.", field: "area")) {
        try feedback.validate()
    }
    feedback = valid
    feedback.fields["zoom"] = "wide"
    #expect(throws: ReportValidationError(.invalidValue, "‘Zoom’ has an invalid value.",
                                          field: "zoom")) { try feedback.validate() }
    feedback = valid
    feedback.fields["copies"] = 2.5
    #expect(throws: ReportValidationError(.invalidValue, "‘Copies’ has an invalid value.",
                                          field: "copies")) { try feedback.validate() }
    feedback = valid
    feedback.contact = " "
    #expect(throws: ReportValidationError(.required, "Contact details are required.",
                                          field: "contact")) { try feedback.validate(contact: .required) }
    try feedback.validate()
    feedback = valid
    feedback.body = " "
    #expect(throws: ReportValidationError(.required, "A description is required.",
                                          field: "body")) { try feedback.validate() }
    #expect(throws: ReportValidationError.self) { try Feedback(title: "", body: "b").content() }
    // A key no question has is sent as it is.
    feedback = valid
    feedback.fields["later"] = 3
    try feedback.validate()
}

@Test func aSetOfQuestionsIsCheckedAsAWhole() throws {
    try ReportField.validate(questions)
    let again = ReportField(key: "area", label: "Again")
    #expect(throws: ReportValidationError(.duplicate, "The field key ‘area’ is defined more than once.",
                                          field: "area")) { try ReportField.validate(questions + [again]) }
    #expect(throws: ReportValidationError.self) { try ReportField.validate([ReportField(key: "area", label: " ")]) }
    #expect(throws: ReportValidationError.self) {
        try ReportField.validate((0..<51).map { ReportField(key: "f\($0)", label: "F") })
    }
    #expect(questions.map(\.kind.name) == ["choice", "integer", "number", "boolean", "text"])
    #expect(throws: ReportValidationError.self) {
        try Feedback(title: "t", body: "b", questions: [questions[0], questions[0]]).validate()
    }
}

@Test func whatAPersonEntersBecomesAValueOfTheQuestionsKind() throws {
    let copies = ReportField(key: "copies", label: "Copies", kind: .integer)
    #expect(try copies.value(from: " 12 ") == 12)
    #expect(try copies.value(from: "") == nil)
    #expect(throws: ReportValidationError(.invalidValue, "‘Copies’ needs a whole number.",
                                          field: "copies")) { try copies.value(from: "12a") }
    #expect(throws: ReportValidationError.self) { try copies.value(from: "1.5") }
    let zoom = ReportField(key: "zoom", label: "Zoom", kind: .number)
    #expect(try zoom.value(from: "1.5") == 1.5 && zoom.value(from: "2") == 2)
    #expect(throws: ReportValidationError(.invalidValue, "‘Zoom’ needs a number.",
                                          field: "zoom")) { try zoom.value(from: "wide") }
    let flag = ReportField(key: "beta", label: "In the beta", kind: .boolean)
    #expect(try flag.value(from: "true") == true && flag.value(from: "false") == false)
    #expect(try questions[0].value(from: "canvas") == "canvas")
    #expect(try ReportField(key: "note", label: "Note").value(from: "12") == "12")
}

@Test func unsafeAndRepeatedAttachmentNamesAreRejected() {
    let file = ReportFile(name: "../file.txt", contentType: "text/plain", data: Data())
    #expect(throws: ReportValidationError.self) {
        try Feedback(title: "Sample", body: "Details", files: [file]).validate()
    }
    let safe = ReportFile(name: "file.txt", contentType: "text/plain", data: Data())
    #expect(throws: ReportValidationError.self) {
        try Feedback(title: "Sample", body: "Details", files: [safe, safe]).validate()
    }
}

@Test func aReportsFilesAreBoundedTogetherNotOneByOne() throws {
    let half = ReportFile(name: "a", contentType: "x/y", data: Data(count: ReportLimits.attachmentBytes / 2))
    let other = ReportFile(name: "b", contentType: "x/y", data: Data(count: ReportLimits.attachmentBytes / 2))
    try ReportContent(title: "t", files: [half, other]).validate()
    let many = (0..<200).map { ReportFile(name: "f\($0)", contentType: "x/y", data: Data()) }
    try ReportContent(title: "t", files: many).validate()
    let one = ReportFile(name: "c", contentType: "x/y", data: Data(count: 1))
    #expect(throws: ReportValidationError(.limitExceeded, "Attachments must total at most 10 MB.", field: "files")) {
        try ReportContent(title: "t", files: [half, other, one]).validate()
    }
}

@Test func fieldBoundsCountUnicodeScalars() throws {
    try ReportLimits.validateFields([String(repeating: "é", count: 64): .text(String(repeating: "é", count: 1_000))])
    #expect(throws: ReportValidationError.self) {
        try ReportLimits.validateFields([String(repeating: "é", count: 65): "value"])
    }
    #expect(throws: ReportValidationError.self) {
        try ReportLimits.validateFields(["key": .text(String(repeating: "é", count: 1_001))])
    }
    #expect(throws: ReportValidationError.self) {
        let fields = (0..<51).map { ("key\($0)", ReportValue.text("value")) }
        try ReportLimits.validateFields(Dictionary(uniqueKeysWithValues: fields))
    }
    #expect(throws: ReportValidationError.self) { try ReportLimits.validateFields(["ratio": .number(.infinity)]) }
}

@Test func aValueKeepsItsTypeThroughTheSealedText() throws {
    let text = ReportText(title: "t", body: "b",
                          fields: ["document": "Untitled 3", "retries": 3, "ratio": 0.5, "pro": true])
    let json = String(decoding: try text.encoded(), as: UTF8.self)
    #expect(json.contains(#""fields":{"document":"Untitled 3","pro":true,"ratio":0.5,"retries":3}"#))
    #expect(!json.contains("schema"))
    #expect(try ReportText.decode(Data(json.utf8)) == text)
    #expect(text.fields.mapValues(\.description) == ["document": "Untitled 3", "retries": "3", "ratio": "0.5",
                                                     "pro": "true"])
    let count = 4
    #expect(ReportValue(count) == 4 && ReportValue("a") == "a" && ReportValue(true) == true)
}

@Test func textSealedBeforeFieldsHadTypesStillOpens() throws {
    let earlier = #"{"body":"b","contact":"me@example.test","labels":["area:arrows"],"#
        + #""metadata":{"retries":"3"},"title":"t"}"#
    #expect(try ReportText.decode(Data(earlier.utf8))
            == ReportText(title: "t", body: "b", contact: "me@example.test", labels: ["area:arrows"],
                          fields: ["retries": "3"]))
}

@Test func aKindThisVersionDoesNotKnowIsKeptAsItWasWritten() throws {
    let written = #"{"body":"b","fields":{"when":"today"},"labels":[],"#
        + #""schema":[{"key":"when","kind":"date","label":"When"}],"title":"t"}"#
    let text = try ReportText.decode(Data(written.utf8))
    #expect(text.fieldDescriptions.first?.kind == .unknown("date"))
    #expect(String(decoding: try text.encoded(), as: UTF8.self) == written)
    #expect(["text", "integer", "number", "boolean", "choice"].map { FieldKind(rawValue: $0).rawValue }
            == ["text", "integer", "number", "boolean", "choice"])
    #expect(FieldKind(rawValue: "choice") == .choice)
}

@Test func whatAnAppSaysOfItsFieldsIsChecked() throws {
    let fields: [String: ReportValue] = ["area": "export", "copies": 2]
    func check(_ descriptions: [FieldDescription]) throws {
        try ReportContent(title: "t", fields: fields, fieldDescriptions: descriptions).validate()
    }
    try check([FieldDescription(key: "area", label: "Area", kind: .choice, option: "Export")])
    let undescribed = "‘zoom’ is described but the report has no such field."
    #expect(throws: ReportValidationError(.invalidDescription, undescribed, field: "zoom")) {
        try check([FieldDescription(key: "zoom", label: "Zoom", kind: .number)])
    }
    #expect(throws: ReportValidationError(.duplicate, "‘area’ is described more than once.", field: "area")) {
        try check([FieldDescription(key: "area", label: "Area", kind: .text),
                   FieldDescription(key: "area", label: "A", kind: .text)])
    }
    for label in ["", " ", String(repeating: "l", count: ReportLimits.fieldLabelLength + 1)] {
        #expect(throws: ReportValidationError.self) {
            try check([FieldDescription(key: "area", label: label, kind: .text)])
        }
    }
    let longOption = String(repeating: "o", count: ReportLimits.fieldLabelLength + 1)
    #expect(throws: ReportValidationError.self) {
        try check([FieldDescription(key: "area", label: "Area", kind: .choice, option: longOption)])
    }
    #expect(throws: ReportValidationError.self) {
        try check([FieldDescription(key: "area", label: "Area", kind: .unknown("x"))])
    }
    // At most one for each field, so no more than there may be fields.
    #expect(ReportLimits.fieldCount == 50)
}

@Test func numericQuestionsAcceptSignedAndUnsignedIntegersExactly() throws {
    for kind in [ReportField.Kind.number, .integer] {
        let field = ReportField(key: "reference", label: "Reference", kind: kind)
        #expect(try field.value(from: "-9223372036854775808") == .integer(.min))
        #expect(try field.value(from: "9007199254740993") == .integer(9_007_199_254_740_993))
        #expect(try field.value(from: "18446744073709551615") == .unsignedInteger(.max))
        try field.validate(value: .integer(.min))
        try field.validate(value: .unsignedInteger(.max))
        for overflow in ["-9223372036854775809", "+18446744073709551616"] {
            let message = "‘Reference’ is outside the supported integer range."
            #expect(throws: ReportValidationError(.unrepresentableNumber, message, field: "reference")) {
                try field.value(from: overflow)
            }
        }
    }
}
