# Customizing the feedback form

Ask your own questions, start from what your app already knows, offer files, and add your own sections.

## Overview

At the top of the form is your app's icon and "Provide Feedback to" your app's name, read from its bundle.
Below that:

- **Basic Information:** a title, your own questions, and an email address unless you say not to ask. What the
  person must fill in is marked with a red asterisk, which VoiceOver reads as "required".
- **Details:** your app's version, the system, the device and the language, then the values your app set.
- **Description.**
- **Included in This Report:** each file, with an icon for its kind and a preview for images, PDFs and UTF-8
  text. A lock marks required files, and a trash button removes optional ones. **Add Attachments** lets the
  person add files of their own.

Submit Report becomes available once required fields are complete and the files have loaded. If something can't
be sent, such as a title that is too long, the form says what to change. Cancel, and Esc on the Mac, ask before
throwing away what the person wrote. On the Mac the form opens at 560 by 720 points, larger with a larger text
size.

Everything below works the same on ``FeedbackForm``, for a form you place yourself, and on
`feedbackSheet(isPresented:)`.

### Your own words

The form's own text is localized through the kit's string catalog. What you pass as `header:` and
`descriptionPrompt:` is looked up in your app's string catalog:

```swift
.feedbackSheet(
    isPresented: $showsFeedback,
    header: "Report a Problem",
    descriptionPrompt: "What were you doing when it happened?")
```

### Ask your own questions

```swift
.feedbackSheet(
    isPresented: $showsFeedback,
    asking: [
        ReportField(key: "area", label: "Area", kind: .choice([
            .init("canvas", label: "Canvas"),
            .init("export", label: "Export"),
        ]), required: true),
        ReportField(key: "copies", label: "Copies", kind: .integer),
        ReportField(key: "document", label: "Document", asked: false),
    ],
    contact: .required)
```

| A question's | |
|---|---|
| `key` | The name its answer is sent under |
| `label` | What the form and Flight Data Recorder call it |
| `kind` | `.text`, `.integer`, `.number`, `.boolean` or `.choice` |
| `required` | Whether the feedback must have it |
| `help` | A line under the control |
| `asked` | Whether the form asks the person. Say `false` for a value your app sets itself; it is listed under Details |

Each question's label, kind and order travel sealed with the feedback, so Flight Data Recorder shows the answer
as you described it, with nothing to set up there. The email address is `.optional` unless you say `.required`
or `.none`. In a debug build, questions that can't make a valid report, such as two with the same key, stop the
app as soon as the form is made.

### Start with what you already know

```swift
.feedbackSheet(
    isPresented: $showsFeedback,
    draft: Feedback(title: "", fields: ["area": "export", "document": "Untitled 3"]),
    asking: questions,
    fixedKeys: ["area"])
```

`fixedKeys` are questions the person sees but can't change. The form reads its draft, questions and attachments
when it first appears. A sheet starts again each time it opens; to start over a form you place yourself, give it
a new identity with `.id(_:)`.

### Offer files

```swift
.feedbackSheet(isPresented: $showsFeedback, attachments: [
    FeedbackAttachment(
        ReportFile(name: "window.png", contentType: "image/png", data: screenshot),
        summary: "The window as it is now"),
    FeedbackAttachment(
        ReportFile(name: "drawing.json", contentType: "application/json", data: document),
        summary: "The drawing you have open",
        required: true),
])
```

A required file can be looked at but not left out.

### Add to it before it goes

```swift
.feedbackSheet(isPresented: $showsFeedback, prepare: { feedback in
    feedback.fields["copies"] = 2
    feedback.files.append(ReportFile(name: "log.txt", contentType: "text/plain", data: log))
}, onQueued: { id in
    lastFeedbackID = id
})
```

If `prepare` changes the feedback, the person reviews the result before it is sent; throwing keeps the form open
with your error. **Edit Feedback** goes back to the form, and the next submission prepares it again. `onQueued`
receives the report's UUID once it is saved on the device.

### Add your own sections

```swift
.feedbackSheet(isPresented: $showsFeedback) {
    Section("Before you send") {
        Text("We read every report.")
    }
}
```
