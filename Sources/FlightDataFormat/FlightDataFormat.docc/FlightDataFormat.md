# ``FlightDataFormat``

Seal, pack and open Flight Data reports.

## Overview

This module is the report format itself: how a report's text and files are sealed to the developer's public key,
how its files are archived, and what the report JSON holds. Apps don't need it: FlightData seals and sends
their reports. Tools that open reports, such as Flight Data Recorder, use it with the private key.

```swift
let opened = try Envelope.open(sealed, using: privateKey, reportID: id, part: .text)
let text = try ReportText.decode(opened)
let files = try Payload.unpack(try Envelope.open(payload, using: privateKey, reportID: id, part: .payload))
```

<doc:Format> describes every byte, for writing a reader in another language.

## Topics

### The format

- <doc:Format>

### Reports

- ``PreparedReport``
- ``ReportContent``
- ``ReportText``
- ``ReportKind``
- ``AppInfo``
- ``ReportLimits``
- ``ReportValidationError``

### Fields and files

- ``ReportValue``
- ``FieldDescription``
- ``FieldKind``
- ``ReportFile``

### Sealing

- ``Envelope``
- ``EnvelopeError``
- ``PrivateKeyPEM``

### Archives

- ``Payload``
- ``PayloadError``
