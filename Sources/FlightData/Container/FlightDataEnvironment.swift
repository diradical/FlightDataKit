// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

#if canImport(SwiftUI)
import SwiftUI

extension EnvironmentValues {
    /// The container the views here send their reports to, which `flightDataContainer(_:)` sets.
    ///
    /// Without one above a view, it is a stand-in that has no report types: sending a report to it stops a debug
    /// build, and in a release build ``FlightDataContainer/submit(_:)`` throws ``FlightDataError/notConfigured``.
    public var flightDataContainer: FlightDataContainer {
        get { self[FlightDataContainerKey.self] }
        set { self[FlightDataContainerKey.self] = newValue }
    }
}

private struct FlightDataContainerKey: EnvironmentKey {
    static let defaultValue = FlightDataContainer.placeholder
}

@MainActor
extension Scene {
    /// Gives every window of this scene the container, as `modelContainer(_:)` does a model container. Make the
    /// container once, as a property of the app, so that it is there from launch.
    public func flightDataContainer(_ container: FlightDataContainer) -> some Scene {
        environment(\.flightDataContainer, container)
    }
}

@MainActor
extension View {
    /// Gives this view and everything in it the container. Use the scene's `flightDataContainer(_:)` where there
    /// is a scene; this one is for a view shown some other way, and for previews.
    public func flightDataContainer(_ container: FlightDataContainer) -> some View {
        environment(\.flightDataContainer, container)
    }
}
#endif
