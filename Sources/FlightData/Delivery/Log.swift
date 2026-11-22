// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import OSLog

/// Where the kit logs, under the subsystem `dev.flightdata.kit`. It logs report IDs and reasons, never what a report
/// says.
enum Log {
    /// The container's setup, and calls an app makes that can't work.
    static let setup = Logger(subsystem: "dev.flightdata.kit", category: "setup")
    /// Sending, retrying and dropping reports.
    static let delivery = Logger(subsystem: "dev.flightdata.kit", category: "delivery")
    /// Gathering periodic reports.
    static let periodic = Logger(subsystem: "dev.flightdata.kit", category: "periodic")
    /// Turning telemetry off, and erasing what was gathered.
    static let telemetry = Logger(subsystem: "dev.flightdata.kit", category: "telemetry")
}

extension Logger {
    /// Logs `message` as it is. The kit's messages hold only report IDs, channel names and reasons, so they are
    /// public.
    func log(_ level: OSLogType, _ message: String) {
        log(level: level, "\(message, privacy: .public)")
    }
}
