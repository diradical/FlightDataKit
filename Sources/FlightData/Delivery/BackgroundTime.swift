// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import Foundation

/// Runs work so that it keeps going for a while if the app is put in the background meanwhile. Only iOS gives an
/// app that time; elsewhere the work simply runs.
enum BackgroundTime {
    /// Runs `work` inside an expiring activity and returns when it is done. If the system takes the time back first,
    /// the work's task is cancelled, which ends an upload in flight, and this returns once the work has wound down.
    static func run(_ work: @escaping @Sendable () async -> Void) async {
        #if os(iOS)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let job = Job(work) { done.resume() }
            // Returns at once. The system calls the block on a queue of its own, and the block is what blocks.
            ProcessInfo.processInfo.performExpiringActivity(withReason: "Uploading Flight Data reports") { expired in
                job.handle(expired: expired)
            }
        }
        #else
        await work()
        #endif
    }

    /// The work as a task that an activity's blocking block can wait for and its expiry call can cancel. The task
    /// starts once, and `finished` is called once, when it ends.
    final class Job: @unchecked Sendable {
        private let work: @Sendable () async -> Void
        private let finished: @Sendable () -> Void
        private let ended = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var task: Task<Void, Never>?

        init(_ work: @escaping @Sendable () async -> Void, finished: @escaping @Sendable () -> Void) {
            self.work = work
            self.finished = finished
        }

        /// The system's call. With time, starts the work and blocks the thread until it ends. Out of time before
        /// the work started, starts it anyway and doesn't wait. Out of time after, cancels it.
        func handle(expired: Bool) {
            if expired {
                lock.withLock {
                    if let task { task.cancel() } else { start() }
                }
            } else {
                lock.withLock { if task == nil { start() } }
                ended.wait()
            }
        }

        /// Called with the lock held.
        private func start() {
            let work = work, finished = finished, ended = ended
            task = Task {
                await work()
                ended.signal()
                finished()
            }
        }
    }
}
