// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

/// What sort of report it is. The server can read it.
public enum ReportKind: String, Codable, Hashable, Sendable {
    /// What a person wrote to the developer.
    case feedback
    /// A crash the app recorded.
    case crash
    /// What an app records on its own about how it is used. It is sent only while the person allows telemetry.
    case telemetry
}
