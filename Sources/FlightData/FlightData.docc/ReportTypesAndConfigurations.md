# Report types and configurations

Define your own reports, route them to the right key, and know what a report may hold.

## Overview

A container sends the report types listed in its schema. Each configuration says how some of those types are
saved and which public key they are sealed to.

### Your own report types

A one-off report implements ``FlightDataReport/content()``, or adopts ``FieldFlightDataReport`` and lists its
outgoing fields. A periodic report also adopts ``PeriodicFlightDataReport``, which uses `Codable` to keep it on
the device and ``PeriodicFlightDataReport/merge(_:)`` to fold events together. Give its channel and fields stable
names, so that a Swift refactor keeps the report stream together in Flight Data Recorder.

```swift
struct BankingAnalytics: PeriodicFlightDataReport, FieldFlightDataReport {
    static let name = "BankingAnalytics"
    var transfers = 0
    var usesBillPay = false

    var reportFields: [String: ReportValue] {
        ["transfers": ReportValue(transfers), "usesBillPay": ReportValue(usesBillPay)]
    }

    mutating func merge(_ newer: BankingAnalytics) {
        transfers += newer.transfers
        usesBillPay = usesBillPay || newer.usesBillPay
    }
}
```

A type can say more of itself than its properties do:

| | Unless it says otherwise | |
|---|---|---|
| `static var name` | The type's name | The report's channel |
| `static var kind` | `.telemetry` | What sort of report it is to the server: `.feedback` or `.crash` for a type that is one |
| `func content()` | Built from `reportFields` | The title, description, contact details, fields and files to seal, and optional `app` details |

`app` is the build a report is about when that isn't the one running. A crash is about the build that crashed,
which an update may have replaced by the time it is sent.

A ``ReportValue`` keeps whole numbers in the 64-bit range exact, and any other number is a `Double`. Send
identifiers that can exceed 64 bits, or whose leading zeroes matter, as text.

``ReflectedFlightDataReport`` opts into a field for every stored property, private ones included. Reflection uses
the Swift property names and ignores `CodingKeys`. A property can be text, a number, `Bool`, a `RawRepresentable`
of one of those, or an optional of one; any other type, such as `Date` or a nested struct, stops a debug build.
Choose it only for types whose stored properties are all meant for the reader.

### Configurations

```swift
let container = FlightDataContainer(
    for: ReportSchema([Feedback.self, BankingAnalytics.self]),
    appToken: "fdk_…",
    configurations:
        FlightDataConfiguration(publicKey: "fdpk2_…"),
        FlightDataConfiguration(periodic: BankingAnalytics.self, every: .days(7), publicKey: "fdpk2_…"))
```

| | |
|---|---|
| `for:` | The types it covers. One that names none covers every type the others don't |
| `periodic:every:` | One periodic type and its interval. Every periodic type needs one |
| `publicKey:` | The key its reports are sealed to, so that different types can have different readers |

A setup that can't work stops a debug build with the reason, and in a release build it is logged as a fault and
the container sends nothing. That covers a malformed app token or key, an invalid or duplicate channel, missing
or overlapping routes, a type outside the schema, a periodic type without a period, and more than one fallback.
A route for a single type takes precedence over the fallback, whatever their order.

### Recording over a period

``FlightDataContainer/record(_:)`` returns at once and doesn't throw. The first event starts a period, and later
events in that period are folded together with your `merge`. When the deadline arrives the container closes the
period and queues the result. If the system suspended or quit the app, the container checks the deadline when
it next runs. An event recorded after the deadline starts a new period.

### Submitting and its errors

``FlightDataContainer/submit(_:)`` checks, seals and queues a report, starts sending it in the background, and
returns its UUID once it is saved on the device. It throws:

- a ``ReportValidationError`` when the report doesn't fit the format, with a stable `reason`, an optional `field`
  key and an English description;
- a ``FlightDataError`` when the container doesn't take it: a type outside the schema, a periodic type, or
  telemetry turned off;
- the file system's error when it can't be saved.

`ReportValidationError.Reason` and `FlightDataError` may gain cases in a later version, so a `switch` over them
needs a `default`.

### Limits

| | |
|---|---|
| Title | 200 characters |
| Description | 5,000 characters |
| Contact details | 254 characters |
| Fields | 50, with keys up to 64 characters and text values up to 1,000 |
| Files | Up to 1,000 files and 10 MB in total; the sealed archive must also fit in 10 MB |
| A file's name | 100 UTF-8 bytes, unique within a report even when compared without case |
| A report type's name | 256 bytes |

``ReportLimits`` has these as constants, and the feedback form checks them as the person types. A plan can set
a smaller limit on a report's files: over it, the server keeps the text and leaves the files out.

### Previews and tests

``FlightDataContainer/preview(for:)`` checks and seals reports and never keeps or sends them:

```swift
#Preview {
    FeedbackForm().flightDataContainer(.preview(for: Feedback.self))
}
```

A view with no container above it gets a stand-in with no report types: sending a report to it stops a debug
build, and in a release build `submit(_:)` throws ``FlightDataError/notConfigured``.
