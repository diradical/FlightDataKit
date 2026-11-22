// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation
#if canImport(Darwin)
import MachO
#endif

extension AppInfo {
    /// The running app, read from its bundle and the system: what a container tells the server unless it is told
    /// otherwise.
    public static func current(bundle: Bundle = .main) -> AppInfo {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return AppInfo(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            platform: platform,
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            deviceModel: deviceModel(),
            locale: Locale.current.identifier(.bcp47),
            binaryUUID: mainExecutableUUID())
    }

    /// True for debug builds and for builds with a sandbox App Store receipt, which TestFlight and development
    /// builds have.
    static func isTestBuild(bundle: Bundle = .main) -> Bool {
        #if DEBUG
        return true
        #else
        return bundle.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }

    private static var platform: String {
        #if os(macOS)
        "macOS"
        #elseif os(iOS)
        "iOS"
        #else
        "unknown"
        #endif
    }

    private static func deviceModel() -> String? {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        #endif
        #if os(macOS)
        let name = "hw.model"
        #else
        let name = "hw.machine"
        #endif
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The LC_UUID of the main executable: what a crash log's symbols are matched against.
    static func mainExecutableUUID() -> String? {
        #if canImport(Darwin)
        guard let header = _dyld_get_image_header(0) else { return nil }
        return header.withMemoryRebound(to: mach_header_64.self, capacity: 1) { header in
            var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
            for _ in 0..<header.pointee.ncmds {
                let load = command.load(as: load_command.self)
                if load.cmd == UInt32(LC_UUID) {
                    let bytes = command.advanced(by: MemoryLayout<load_command>.size).loadUnaligned(as: uuid_t.self)
                    return UUID(uuid: bytes).uuidString.lowercased()
                }
                command = command.advanced(by: Int(load.cmdsize))
            }
            return nil
        }
        #else
        return nil
        #endif
    }
}
