# ``FlightDataFeedback``

The feedback report and the form a person fills it in with.

## Overview

``Feedback`` is a report type that comes with the kit: a title, a description, how to reach the person, the
answers to the app's own questions, and files. List it in the app's schema, and present the form wherever
feedback is asked for:

```swift
import FlightDataFeedback // brings FlightData with it
import SwiftUI

@main
struct YourApp: App {
    // A token or key that can't work stops a debug build with the reason.
    let container = FlightDataContainer(for: Feedback.self, appToken: "fdk_…", publicKey: "fdpk2_…")

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .flightDataContainer(container)
    }
}

struct ContentView: View {
    @State private var showsFeedback = false

    var body: some View {
        Button("Send Feedback…") { showsFeedback = true }
            .feedbackSheet(isPresented: $showsFeedback)
    }
}
```

The form shows the app and device details, the feedback text and its attachments. People can inspect the
files and remove optional attachments.

A draft carries its own questions. Pass `asking:` to replace those questions, or `asking: []` to clear them.
The report seals each field’s key, label and kind alongside its answer. In a debug build, questions that can't
make a valid report, such as two with one key, stop the app when the form is made, before anyone fills it in.

Use `prepare:` to add information before queuing. The form shows any changes for confirmation. Choosing Edit
Feedback runs preparation again on the next submission, so a custom SwiftUI section can supply its current
values. A retry uses the prepared report the person already approved.

`onQueued:` runs once after local submission succeeds and receives that report’s UUID. The container uploads
it asynchronously. A preview container simulates a successful submission.

```swift
struct ContentView: View {
    @State private var showsFeedback = false
    @State private var lastQueuedReport: UUID?

    var body: some View {
        Button("Send Feedback…") { showsFeedback = true }
            .feedbackSheet(
                isPresented: $showsFeedback,
                draft: Feedback(title: "", questions: [ReportField(key: "build", label: "Build", asked: false)]),
                prepare: { report in report.fields["build"] = "42" },
                onQueued: { id in lastQueuedReport = id }
            )
    }
}
```

### Where the form starts

The form reads its draft, questions and attachments when it is first shown, and keeps what the person types
until they send or discard it. A sheet starts again each time it opens. A form you place yourself keeps its
state for as long as its identity lasts, so give it a new one with `id(_:)` to start over, for example when
the document it is about changes.

### Languages

The form's own text comes in the kit's string catalog. The `header:` and `descriptionPrompt:` you pass are
looked up in your app's main bundle, so put them in your app's string catalog. Question labels, help and
option labels are sent with the report as you give them; localize them before you make the questions.

## Topics

### Essentials

- <doc:CustomizingTheForm>

### The report

- ``Feedback``
- ``ReportField``

### The form

- ``SwiftUICore/View/feedbackSheet(isPresented:draft:asking:contact:header:descriptionPrompt:fixedKeys:attachments:prepare:onQueued:)``
- ``SwiftUICore/View/feedbackSheet(isPresented:draft:asking:contact:header:descriptionPrompt:fixedKeys:attachments:extra:prepare:onQueued:)``
- ``FeedbackForm``
- ``FeedbackAttachment``
