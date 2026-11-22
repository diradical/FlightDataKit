// swift-tools-version: 6.0
// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import PackageDescription

let package = Package(
    name: "FlightDataKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "FlightData", targets: ["FlightData"]),
        .library(name: "FlightDataFeedback", targets: ["FlightDataFeedback"]),
        .library(name: "FlightDataFormat", targets: ["FlightDataFormat"]),
    ],
    targets: [
        // The sealed format and what goes on the wire. Tools that open reports use it.
        .target(name: "FlightDataFormat"),
        // What every app uses: report types, the schema, configurations and the container.
        .target(name: "FlightData", dependencies: ["FlightDataFormat"], resources: [.copy("PrivacyInfo.xcprivacy")]),
        // The feedback report and its form.
        .target(name: "FlightDataFeedback", dependencies: ["FlightData"],
                resources: [.process("Resources"), .copy("PrivacyInfo.xcprivacy")]),
        .testTarget(name: "FlightDataTests", dependencies: ["FlightData", "FlightDataFeedback", "FlightDataFormat"]),
        .testTarget(name: "PublicAPITests", dependencies: ["FlightData", "FlightDataFeedback", "FlightDataFormat"]),
    ],
    swiftLanguageModes: [.v6]
)
