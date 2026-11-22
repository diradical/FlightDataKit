# Privacy and telemetry consent

What the server can read, what stays sealed, and how the person's choice about telemetry is kept.

## Overview

A report's text, fields and files are sealed to the developer's public key before they are kept on the device.
The server stores them and can't open them; Flight Data Recorder opens them on the developer's Mac. Some things
travel readable, because the server needs them to take, count and sort reports.

### What travels readable

| | What it is |
|---|---|
| The report's ID | A random UUID made for the report |
| Its kind | Feedback, crash or telemetry |
| Its channel | The report type's name |
| The key ID | Which public key it is sealed to: the start of the key's SHA-256 |
| Whether it is a test | True for debug builds and TestFlight builds |
| The app's version and build | From the app's bundle, or the build a crash report is about |
| The system | `macOS` or `iOS`, and its version |
| The device's model | Such as `Mac16,1` or `iPhone17,1` |
| The locale | The person's language and region, such as `en-US` |
| The executable's UUID | What a crash log's symbols are matched against |
| The app token | Which app the report is for. It ships inside the app and is not a secret |
| The install ID | 32 random hexadecimal digits the kit makes on the device |
| The kit's version | In the `User-Agent` header |

The install ID is kept in the app's keychain on the device, so it survives the app being deleted and installed
again. It is sent with every report, feedback and crashes included, also after the person turns telemetry off.
The server keeps only a keyed hash of it, to count installs and to stop one that misbehaves.

Where App Attest is available, the key the copy enrolled is named by its App Attest key ID on each report, with
the server's challenge and the signature. Enrolling sends that key ID, Apple's attestation of the key and the
App ID prefix the app is signed with. The server sees the address a report comes from while it arrives, and
keeps only a keyed hash of it, for rate limits.

### What stays sealed

The title, the description, the contact details, the app's own fields and what it says of them, and every file.

On the device, a queued report is already sealed. A periodic report being gathered is kept as its `Codable`
JSON, with properties its `content()` leaves out, until it is sealed at the end of its period; on iOS the
system encrypts it until the device's first unlock after it starts. The kit's folder is left out of backups.

### Telemetry consent

Reports of kind ``ReportKind/telemetry`` are what an app records on its own about how it is used. They are
sent only while the person allows it; feedback and crash reports are sent either way.

Ask the person in your app, and tell the container what they chose with
``FlightDataContainer/setTelemetryEnabled(_:)``. The kit remembers the choice in its own folder, so a container
made at the next launch keeps it. Telemetry is allowed until the person says otherwise. An app that keeps the
choice itself can pass it as `telemetryEnabled:` when it makes the container, and it applies over what the kit
remembered.

Turning telemetry off erases what was gathered and not yet sent: the periodic reports being gathered, and the
telemetry reports queued. An upload in progress is cancelled; a report the server already has can't be
recalled. While telemetry is off, ``FlightDataContainer/record(_:)`` ignores telemetry, and
``FlightDataContainer/submit(_:)`` throws ``FlightDataError/telemetryDisabled`` for it. When something can't be
erased at once, it is erased before any telemetry is gathered or sent again.

### App Store privacy labels

Describe the data your app actually sends, which includes the readable data above and what your reports hold.
Each product ships a privacy manifest that Xcode adds to your app's privacy report. `FlightData` declares a device
ID (the install ID), other diagnostic data (the app, system and device details) and product interaction (what
periodic reports count); `FlightDataFeedback` adds customer support (what the person writes and attaches) and
the email address the form can ask for. None is used for tracking, and the kit calls no API that needs a
declared reason.
