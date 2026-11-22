# FlightDataKit

Feedback, crash reports and telemetry from your Mac and iPhone apps, sealed on the device so that only you can
read them.

A person describes what went wrong, attaches a screenshot or the document they had open, and presses Submit.
FlightDataKit encrypts the report to a public key built into your app, keeps it on the device and uploads it to
Flight Data when it can. You read it in Flight Data Recorder on your Mac, which holds the private key. The
server in between stores what it is given and can't open it.

- Swift 6 and Xcode 16, for macOS 14 and iOS 17 or later
- Nothing outside Apple's SDKs
- A Flight Data account on any plan, the free one included. See [License](#license).

## Before you start

Add your app in Flight Data Recorder. It gives you the two values the kit needs:

| | Looks like | What it is |
|---|---|---|
| App token | `fdk_…` | Tells the server which app a report is from |
| Public key | `fdpk2_…` | What reports are sealed to. Copy it from Organizer ▸ Keys |

Both ship inside your app. The private key stays in your Mac's keychain.

## Install

Add the package with Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/diradical/FlightDataKit.git", from: "1.0.0"),
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "FlightDataFeedback", package: "FlightDataKit"),
    ]),
]
```

In a sandboxed Mac app, turn on **Outgoing Connections (Client)** under Signing & Capabilities ▸ App Sandbox. If
people may attach files from Finder, also set **User Selected File** to Read Only.

## Quick start

Make a container and give it to your scene:

```swift
import FlightDataFeedback // brings FlightData with it
import SwiftUI

@main
struct YourApp: App {
    private let flightData = FlightDataContainer(for: Feedback.self, appToken: "fdk_…", publicKey: "fdpk2_…")

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .flightDataContainer(flightData)
    }
}
```

Then show the form wherever you ask for feedback:

```swift
struct ContentView: View {
    @State private var showsFeedback = false

    var body: some View {
        Button("Send Feedback…") { showsFeedback = true }
            .feedbackSheet(isPresented: $showsFeedback)
    }
}
```

That's all. The form queues the report when the person confirms it, and the kit sends it in the background,
across launches if it has to. Send yourself a report from a debug build and open it in Flight Data Recorder to
check the setup.

Setting up doesn't throw. A token or key that can't work is a mistake in the app: a debug build stops and says
why, and a release build logs it and sends nothing.

## Everyday use

Send a report from code, with the container (in a view, `@Environment(\.flightDataContainer)` gives it to you):

```swift
var feedback = Feedback(title: "Export failed", body: "Exporting to PDF stopped at page 3.")
feedback.fields["document"] = "Untitled 3"
let id = try await flightData.submit(feedback)
```

Ask your own questions in the form, and offer files the person can look at before sending:

```swift
.feedbackSheet(
    isPresented: $showsFeedback,
    asking: [
        ReportField(key: "area", label: "Area", kind: .choice([
            .init("canvas", label: "Canvas"),
            .init("export", label: "Export"),
        ]), required: true),
    ],
    attachments: [
        FeedbackAttachment(
            ReportFile(name: "window.png", contentType: "image/png", data: screenshot),
            summary: "The window as it is now"),
    ])
```

Count things as they happen with a report type of your own, gathered over a period and sent once at its end:

```swift
struct Usage: PeriodicFlightDataReport, ReflectedFlightDataReport {
    static let name = "Usage"
    var exports = 0

    mutating func merge(_ newer: Usage) { exports += newer.exports }
}

let flightData = FlightDataContainer(
    for: ReportSchema([Feedback.self, Usage.self]),
    appToken: "fdk_…",
    configurations:
        FlightDataConfiguration(publicKey: "fdpk2_…"),
        FlightDataConfiguration(periodic: Usage.self, every: .days(7), publicKey: "fdpk2_…"))

flightData.record(Usage(exports: 1))
```

Telemetry is on until the person turns it off. When they do, call
`await flightData.setTelemetryEnabled(false)`: what was gathered and not yet sent is erased, and feedback and
crash reports are still sent.

## What a report carries

| Sealed: only you can read it | Readable by the server |
|---|---|
| The title and description | The kind: feedback, crash or telemetry |
| Contact details, if given | The channel: the report type's name |
| Your fields, and what you call them | The ID of the key it is sealed to |
| Every file the person didn't remove | App version and build, and the main executable's UUID |
| | Platform, OS version, device model, language and region |
| | Whether it is a test build (debug or TestFlight) |
| | A random install ID, kept in the device's keychain |
| | With App Attest, the key ID the report is signed with |

Each product ships a privacy manifest that Xcode adds to your app's privacy report. No data is used for
tracking. Describe what your reports hold in your App Store privacy label.

## Documentation

The DocC catalogs cover the rest. In Xcode, choose Product ▸ Build Documentation.

- **Report types and configurations:** your own report types, routing to different keys, errors, limits,
  previews and tests.
- **Customizing the feedback form:** your own questions and wording, starting from what you know, files, and
  your own sections.
- **Delivery and retention:** when reports are sent, what the server's answers do, the 30-day limit, background
  delivery and App Attest.
- **Privacy and telemetry consent:** exactly what travels readable, and how the person's choice is kept.
- **The sealed report format:** the encryption and the wire format, for tools that open reports.

| Product | Holds |
|---|---|
| `FlightDataFeedback` | `Feedback`, its questions, the form and `feedbackSheet`. It brings `FlightData` with it |
| `FlightData` | Report types, the schema, configurations, the container and the scene modifier |
| `FlightDataFormat` | The sealed format, for tools that open reports. An app doesn't need it |

## Versioning

FlightDataKit follows semantic versioning. Within a major version, code that compiles keeps compiling, and
reports keep the same format. `ReportValidationError.Reason` and `FlightDataError` may gain cases, so a
`switch` over them needs a `default`.

The kit doesn't record crashes itself, so it needs nothing outside Apple's SDKs. An app that records crashes
can send each one as a report type of its own, with the kind `.crash`.

## License

FlightDataKit is source-available, not open source. You may use it with a Flight Data account on any plan,
including the free one, to send your apps' reports to Flight Data, also in apps you build for a client who has
an account. Anyone may read the source. The terms are in [LICENSE](LICENSE).

Copyright © 2026 Diradical LLC.
