// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation

/// What a report says about the app and the device it comes from. The server can read it.
public struct AppInfo: Codable, Equatable, Sendable {
    /// The app's version, its `CFBundleShortVersionString`. At most 32 characters.
    public var version: String
    /// The app's build, its `CFBundleVersion`. At most 32 characters.
    public var build: String?
    /// The system: `macOS` or `iOS`. At most 32 characters.
    public var platform: String?
    /// The system's version, such as `26.0.1`. At most 64 characters.
    public var osVersion: String?
    /// The device's model identifier, such as `Mac16,1`. At most 64 characters.
    public var deviceModel: String?
    /// The language and region as a BCP 47 tag, such as `en-US`. At most 35 characters.
    public var locale: String?
    /// The UUID of the app's main executable, which a crash log's symbols are matched against.
    public var binaryUUID: String?

    /// The JSON key and the most characters of each value the server accepts.
    private enum Limit {
        static let version = ("version", 32)
        static let build = ("build", 32)
        static let platform = ("platform", 32)
        static let osVersion = ("os_version", 64)
        static let deviceModel = ("device_model", 64)
        static let locale = ("locale", 35)
    }

    /// Values longer than the server accepts are cut, not refused: these only label a report.
    public init(version: String, build: String? = nil, platform: String? = nil, osVersion: String? = nil,
                deviceModel: String? = nil, locale: String? = nil, binaryUUID: String? = nil) {
        self.version = Self.clamp(version, Limit.version.1) ?? ""
        self.build = Self.clamp(build, Limit.build.1)
        self.platform = Self.clamp(platform, Limit.platform.1)
        self.osVersion = Self.clamp(osVersion, Limit.osVersion.1)
        self.deviceModel = Self.clamp(deviceModel, Limit.deviceModel.1)
        self.locale = Self.clamp(locale, Limit.locale.1)
        self.binaryUUID = binaryUUID
    }

    /// The `app` object of the report JSON. Long values are cut again, since the properties can be set after the
    /// initializer; a NUL or a malformed binary UUID is refused.
    func wireValues() throws -> [String: String] {
        guard !version.isEmpty else {
            throw ReportValidationError(.required, "The report needs an app version.", field: "app.version")
        }
        var object: [String: String] = [:]
        let values = [(Limit.version, Optional(version)), (Limit.build, build), (Limit.platform, platform),
                      (Limit.osVersion, osVersion), (Limit.deviceModel, deviceModel), (Limit.locale, locale)]
        for ((key, limit), value) in values {
            guard let value = Self.clamp(value, limit) else { continue }
            guard !value.utf8.contains(0) else {
                throw ReportValidationError(.invalidValue, "The app’s \(key) contains a null character.",
                                            field: "app.\(key)")
            }
            object[key] = value
        }
        if let binaryUUID {
            var value = binaryUUID
            if value.utf8.count == 32, let compact = value.wholeMatch(of: /(.{8})(.{4})(.{4})(.{4})(.{12})/) {
                value = "\(compact.1)-\(compact.2)-\(compact.3)-\(compact.4)-\(compact.5)"
            }
            guard value.utf8.count == 36, let uuid = UUID(uuidString: value) else {
                throw ReportValidationError(.invalidValue, "The app’s binary UUID must be a valid UUID.",
                                            field: "app.binary_uuid")
            }
            object["binary_uuid"] = uuid.uuidString.lowercased()
        }
        return object
    }

    private static func clamp(_ value: String?, _ limit: Int) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return String(value.unicodeScalars.prefix(limit))
    }
}
