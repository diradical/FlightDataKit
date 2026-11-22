// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The running app's name and icon, read from its bundle, for the form's header.
enum AppIdentity {
    /// The name people see: the display name, else the bundle name, else the process name.
    static var name: String {
        let bundle = Bundle.main
        return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
    }

    /// The app's icon. On iOS, the largest icon file the bundle names, under the iPad's list first, or nil when it
    /// names none that loads.
    @MainActor static var icon: Image? {
        #if os(macOS)
        return Image(nsImage: NSApplication.shared.applicationIconImage)
        #elseif canImport(UIKit)
        let icons = (Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons~ipad")
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons")) as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let files = primary?["CFBundleIconFiles"] as? [String] ?? []
        let names = files.reversed() + [primary?["CFBundleIconName"] as? String].compactMap { $0 }
        return names.lazy.compactMap { UIImage(named: $0) }.first.map { Image(uiImage: $0) }
        #else
        return nil
        #endif
    }
}
