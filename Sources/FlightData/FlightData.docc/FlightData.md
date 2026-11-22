# ``FlightData``

Send feedback, crash reports and telemetry from your app, sealed on the device so that only you can read them.

## Overview

Make one container at launch, for the report types your app sends, and give it to your scene:

```swift
import FlightData
import FlightDataFeedback
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

Flight Data Recorder gives you the app token and the public key when you add the app there. Both ship in the
app; the private key stays on your Mac. Setting up doesn't throw: a token or a key that can't work stops a
debug build with the reason.

A report the app sends on its own, such as feedback the person wrote, is submitted. The container checks it,
seals it, keeps it on the device and sends it in the background:

```swift
struct ReportButton: View {
    @Environment(\.flightDataContainer) private var flightData

    var body: some View {
        Button("Send") {
            Task { try await flightData.submit(Feedback(title: "Export fails", body: "At page 3.")) }
        }
    }
}
```

### Gathering over a period

A periodic type gathers what the app records over a period, and is sent once at the end of it:

```swift
struct BankingAnalytics: PeriodicFlightDataReport, FieldFlightDataReport {
    static let name = "BankingAnalytics"
    var transfers = 0

    var reportFields: [String: ReportValue] { ["transfers": ReportValue(transfers)] }

    mutating func merge(_ newer: BankingAnalytics) { transfers += newer.transfers }
}

let flightData = FlightDataContainer(
    for: ReportSchema([Feedback.self, BankingAnalytics.self]),
    appToken: "fdk_…",
    configurations:
        FlightDataConfiguration(publicKey: "fdpk2_…"),
        FlightDataConfiguration(periodic: BankingAnalytics.self, every: .days(7), publicKey: "fdpk2_…"))
```

Record as things happen. Recording returns at once and doesn't throw:

```swift
Button("Transfer") { flightData.record(BankingAnalytics(transfers: 1)) }
```

The module follows SwiftData: a report type is like a model type, ``ReportSchema`` lists them,
``FlightDataConfiguration`` says how each is saved and who can read it, and ``FlightDataContainer`` holds them,
given to the scene with `flightDataContainer(_:)`.

## Topics

### Essentials

- <doc:ReportTypesAndConfigurations>
- <doc:DeliveryAndRetention>
- <doc:PrivacyAndTelemetry>

### Report types

- ``FlightDataReport``
- ``FieldFlightDataReport``
- ``ReflectedFlightDataReport``
- ``PeriodicFlightDataReport``

### Setting up

- ``FlightDataContainer``
- ``ReportSchema``
- ``FlightDataConfiguration``
- ``SwiftUI/Scene/flightDataContainer(_:)``
- ``SwiftUICore/View/flightDataContainer(_:)``
- ``SwiftUICore/EnvironmentValues/flightDataContainer``

### Sending

- ``FlightDataContainer/submit(_:)``
- ``FlightDataContainer/record(_:)``
- ``FlightDataError``
- ``ReportValidationError``

### What a report holds

- ``ReportContent``
- ``ReportValue``
- ``FieldDescription``
- ``FieldKind``
- ``ReportFile``
- ``ReportKind``
- ``AppInfo-extension``
- ``ReportLimits``

### The kit

- ``FlightDataKit``
