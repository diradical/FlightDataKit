// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

/// Watches the app and the network for the container: calls `retry` when waiting reports could now go, because
/// the app became active again or the network came back, and `save` when the app is about to be suspended or to
/// quit. The container owns it, and what it watches stops when it goes.
final class DeliveryTriggers: Sendable {
    /// What is watched. Tests give their own.
    struct Inputs: Sendable {
        var center: NotificationCenter
        /// Posted when the app comes back to the foreground.
        var foreground: [Notification.Name]
        /// Posted when the app may be suspended or end: the moment to save what is only in memory.
        var suspension: [Notification.Name]
        /// Whether the network can be used, now and each time it changes.
        var reachability: @Sendable () -> AsyncStream<Bool>

        /// The notification center and `NWPathMonitor` of the running process. A Mac app isn't suspended, so it
        /// isn't watched for coming back to the foreground.
        static var system: Inputs {
            #if canImport(UIKit)
            let foreground = [UIApplication.didBecomeActiveNotification]
            let suspension = [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                              UIApplication.willTerminateNotification]
            #else
            let foreground: [Notification.Name] = []
            // AppKit's names, written out so that the kit doesn't link AppKit into a tool that uses it.
            let suspension = [Notification.Name("NSApplicationWillResignActiveNotification"),
                              Notification.Name("NSApplicationWillTerminateNotification")]
            #endif
            return Inputs(center: .default, foreground: foreground, suspension: suspension, reachability: { paths() })
        }

        /// Nothing at all: for tests, so that only what a test does sends anything.
        static var none: Inputs {
            Inputs(center: NotificationCenter(), foreground: [], suspension: [],
                   reachability: { AsyncStream { $0.finish() } })
        }

        private static func paths() -> AsyncStream<Bool> {
            AsyncStream { continuation in
                let monitor = NWPathMonitor()
                monitor.pathUpdateHandler = { continuation.yield($0.status == .satisfied) }
                continuation.onTermination = { _ in monitor.cancel() }
                monitor.start(queue: DispatchQueue(label: "dev.flightdata.kit.network"))
            }
        }
    }

    /// Tells a network that came back from one that was there all along: only a change from unusable to usable
    /// counts. The first answer only says how things stand.
    struct NetworkReturn {
        private var reachable: Bool?

        /// Whether `now` is the network coming back.
        mutating func update(_ now: Bool) -> Bool {
            defer { reachable = now }
            return now && reachable == false
        }
    }

    private final class Observers: @unchecked Sendable {
        let center: NotificationCenter
        var tokens: [any NSObjectProtocol] = []
        init(_ center: NotificationCenter) { self.center = center }
        deinit { tokens.forEach(center.removeObserver) }
    }

    private let observers: Observers
    private let watching: Task<Void, Never>

    /// `save` is called on the thread that posts the notification, before it returns, so that what it saves is on
    /// disk before the app is suspended.
    init(_ inputs: Inputs, retry: @escaping @Sendable () -> Void, save: @escaping @Sendable () -> Void) {
        let observers = Observers(inputs.center)
        observers.tokens = inputs.foreground.map { name in
            inputs.center.addObserver(forName: name, object: nil, queue: nil) { _ in retry() }
        } + inputs.suspension.map { name in
            inputs.center.addObserver(forName: name, object: nil, queue: nil) { _ in save() }
        }
        self.observers = observers
        let paths = inputs.reachability()
        watching = Task {
            var network = NetworkReturn()
            for await now in paths where network.update(now) { retry() }
        }
    }

    deinit { watching.cancel() }
}
