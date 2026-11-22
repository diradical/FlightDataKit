// Copyright © 2026 Diradical LLC. All rights reserved.
// Use is subject to the Flight Data Recorder SDK License in LICENSE.

import CryptoKit
import FlightDataFormat
import Foundation

/// Seals an app's reports, keeps them on the device and sends them, so that only the developer can read them.
///
/// An app makes one container at launch, as it makes a model container, and gives it to its scene with
/// `flightDataContainer(_:)`. Views get it back from `@Environment(\.flightDataContainer)`.
///
/// ```swift
/// let container = FlightDataContainer(for: Feedback.self, appToken: "fdk_…", publicKey: "fdpk2_…")
/// ```
///
/// A report the app submits with ``submit(_:)`` is checked, sealed and queued on the device; an event it records
/// with ``record(_:)`` joins the period being gathered. The container sends what is queued in the background,
/// and keeps trying across launches: making a container sends what an earlier run left.
///
/// Setting up doesn't throw. A setup that can't work (a malformed app token or key, a type no configuration
/// covers, a periodic type without a period) is a mistake in the app: a debug build stops with the reason, and a
/// release build logs it as a fault and makes a container that sends nothing.
public actor FlightDataContainer {
    /// The report types the app sends.
    public nonisolated let schema: ReportSchema
    /// `fdk_…`, which tells the server which app this is. It ships inside the app and is not a secret.
    public nonisolated let appToken: String
    /// How the types are saved, and who can read them.
    public nonisolated let configurations: [FlightDataConfiguration]
    /// The server, up to its version: requests go to `<endpoint>/v1/reports` and `<endpoint>/v1/attest/…`.
    public nonisolated let endpoint: URL
    /// What the container tells the server about the app: its version, the system and the device.
    public nonisolated let app: AppInfo
    /// Flight Data's server, `https://flightdata.dev/api`.
    public static let defaultEndpoint = URL(string: "https://flightdata.dev/api")!

    /// Everything a container has once its setup checks out.
    struct Setup: Sendable {
        let routes: [ObjectIdentifier: Route]
        let routesByName: [String: Route]
        /// Whether reports are marked as tests.
        let test: Bool
        /// Where the container keeps its files.
        let directory: URL
        /// False for a preview, which checks and seals reports but neither keeps nor sends them.
        let keeps: Bool
        let queue: ReportQueue
        let sender: ReportSender
        let prover: ReportProver
        let installIDs: any InstallIDStore
        /// Nil for a preview.
        let windows: PeriodicWindows?

        /// The period of each periodic type, by channel.
        var periods: [String: TimeInterval] { routesByName.compactMapValues(\.period) }
    }

    /// Nil for a container that sends nothing: its setup was invalid, or it is the stand-in for no container.
    nonisolated let setup: Setup?
    nonisolated let consent: TelemetryConsent
    nonisolated let now: @Sendable () -> Date
    /// Says that the app used the kit in a way that can't work.
    nonisolated let problem: @Sendable (String) -> Void
    /// Whether this is what a view gets when no `flightDataContainer(_:)` is above it.
    private nonisolated let isPlaceholder: Bool

    var passRequested = false
    var delivering: Task<Void, Never>?
    var makeDueRequested = false
    var retryTask: Task<Void, Never>?
    /// When the scheduled retry is due.
    var retryAt: Date?
    /// How many passes have run, for tests.
    var passCount = 0
    /// Passes in a row that met a report or a folder that couldn't be read or written.
    var storageFailures = 0
    var periodicTask: Task<Void, Never>?
    var periodicWake: Date?
    var telemetryUpload: Task<DeliveryOutcome, Never>?
    private var triggers: DeliveryTriggers?

    /// A container for a few types whose reports are each submitted on their own, sealed to one key: the
    /// smallest setup.
    ///
    /// - Parameters:
    ///   - types: The report types the app submits, such as `Feedback`.
    ///   - appToken: The app's token from Flight Data Recorder, `fdk_…`.
    ///   - publicKey: The key reports are sealed to, `fdpk2_…`, from Flight Data Recorder.
    ///   - telemetryEnabled: The person's choice about telemetry, when the app asks for it itself. Nil keeps the
    ///     choice the kit remembers, which starts as allowed.
    public init(for types: any FlightDataReport.Type..., appToken: String, publicKey: String,
                telemetryEnabled: Bool? = nil) {
        self.init(schema: ReportSchema(types), appToken: appToken, endpoint: Self.defaultEndpoint,
                  configurations: [FlightDataConfiguration(publicKey: publicKey)], app: .current(),
                  test: nil, directory: nil, telemetryEnabled: telemetryEnabled)
    }

    /// A container for a schema, with a configuration for how each type is saved and who can read it.
    ///
    /// - Parameters:
    ///   - schema: The report types the app sends.
    ///   - appToken: The app's token from Flight Data Recorder, `fdk_…`.
    ///   - endpoint: The server, up to but not including `/v1`.
    ///   - configurations: How the types are saved and who can read them. One that names no types covers every
    ///     type the others don't, except periodic types, which each need their own.
    ///   - app: What the server is told about the app. Defaults to the running app.
    ///   - marksReportsAsTests: Whether reports are marked as tests, which Flight Data Recorder keeps apart from
    ///     the rest. Nil marks them in debug builds and in TestFlight and other builds with a sandbox receipt.
    ///   - directory: Where the kit keeps its files. Defaults to
    ///     `Application Support/<bundle ID>/FlightData/<token>/`, with `<token>` a hash of the app token.
    ///   - telemetryEnabled: The person's choice about telemetry, when the app asks for it itself. Nil keeps the
    ///     choice the kit remembers, which starts as allowed.
    public init(for schema: ReportSchema, appToken: String, endpoint: URL = FlightDataContainer.defaultEndpoint,
                configurations: FlightDataConfiguration..., app: AppInfo = .current(),
                marksReportsAsTests: Bool? = nil, directory: URL? = nil, telemetryEnabled: Bool? = nil) {
        self.init(schema: schema, appToken: appToken, endpoint: endpoint, configurations: configurations, app: app,
                  test: marksReportsAsTests, directory: directory, telemetryEnabled: telemetryEnabled)
    }

    /// A container for previews and tests: reports are checked and sealed, to a key made for the occasion, and
    /// neither kept nor sent. A periodic type gathers over a day.
    public static func preview(for types: any FlightDataReport.Type...) -> FlightDataContainer {
        let key = Envelope.publicKeyString(Curve25519.KeyAgreement.PrivateKey().publicKey)
        let periodic = types.compactMap { type in
            (type as? any PeriodicFlightDataReport.Type).map { previewConfiguration($0, publicKey: key) }
        }
        return FlightDataContainer(
            schema: ReportSchema(types), appToken: "fdk_" + String(repeating: "0", count: 32),
            endpoint: defaultEndpoint, configurations: [FlightDataConfiguration(publicKey: key)] + periodic,
            app: .current(), test: true, directory: nil, telemetryEnabled: nil, keeps: false,
            installIDs: MemoryInstallIDStore(), triggers: .none)
    }

    /// A container for a schema, as the public initializer makes one, that sends with `session`, takes its install
    /// ID from `installIDs` and its time from `now`: for tests in other packages, which can't reach the kit's
    /// internals.
    @_spi(Testing)
    public init(for schema: ReportSchema, appToken: String, endpoint: URL = FlightDataContainer.defaultEndpoint,
                configurations: [FlightDataConfiguration], app: AppInfo = .current(), marksReportsAsTests: Bool? = nil,
                directory: URL? = nil, telemetryEnabled: Bool? = nil, session: URLSession,
                installIDs: any InstallIDStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(schema: schema, appToken: appToken, endpoint: endpoint, configurations: configurations, app: app,
                  test: marksReportsAsTests, directory: directory, telemetryEnabled: telemetryEnabled,
                  installIDs: installIDs, session: session, now: now)
    }

    private static func previewConfiguration<Report: PeriodicFlightDataReport>(
        _ type: Report.Type, publicKey: String) -> FlightDataConfiguration {
        FlightDataConfiguration(periodic: type, every: .days(1), publicKey: publicKey)
    }

    /// Every part given; the defaults are the device's own. Tests give their own server, clock and stand-ins.
    init(schema: ReportSchema, appToken: String, endpoint: URL, configurations: [FlightDataConfiguration],
         app: AppInfo, test: Bool?, directory: URL?, telemetryEnabled: Bool?, keeps: Bool = true,
         installIDs: any InstallIDStore = KeychainInstallIDStore(), session: URLSession = .shared,
         attestor: any AppAttestor = DeviceAttestor(), now: @escaping @Sendable () -> Date = { Date() },
         triggers: DeliveryTriggers.Inputs = .system, periodicSaveDelay: Duration = .seconds(5),
         problem: @escaping @Sendable (String) -> Void = FlightDataContainer.stop) {
        self.schema = schema
        self.appToken = appToken
        self.endpoint = endpoint
        self.configurations = configurations
        self.app = app
        self.now = now
        self.problem = problem
        isPlaceholder = false
        do {
            guard appToken.wholeMatch(of: /fdk_[0-9a-f]{32}/) != nil else {
                throw FlightDataConfigurationError.invalidAppToken
            }
            let routes = try schema.routes(for: configurations)
            let directory = directory ?? Self.defaultDirectory(appToken: appToken)
            setup = Setup(
                routes: routes, routesByName: Dictionary(uniqueKeysWithValues: routes.values.map { ($0.name, $0) }),
                test: test ?? AppInfo.isTestBuild(), directory: directory, keeps: keeps,
                queue: ReportQueue(root: directory),
                sender: ReportSender(endpoint: endpoint, appToken: appToken, session: session),
                prover: ReportProver(endpoint: endpoint, appToken: appToken, session: session, attestor: attestor,
                                     file: directory.appending(path: "attest.json")),
                installIDs: installIDs,
                windows: keeps ? PeriodicWindows(directory: directory.appending(path: "periodic"),
                                                 saveDelay: periodicSaveDelay) : nil)
        } catch {
            setup = nil
            problem("FlightData isn’t set up, so it will send nothing. \(error)")
        }
        consent = TelemetryConsent(directory: setup.flatMap { $0.keeps ? $0.directory : nil }, choice: telemetryEnabled)
        if setup?.keeps == true {
            Task { await self.start(triggers) }
        }
    }

    /// What a view gets when no `flightDataContainer(_:)` is above it: it has no report types, and sending a
    /// report to it stops a debug build.
    static let placeholder = FlightDataContainer()

    private init() {
        schema = ReportSchema([])
        appToken = ""
        configurations = []
        endpoint = Self.defaultEndpoint
        app = .current()
        setup = nil
        consent = TelemetryConsent(directory: nil, choice: nil)
        now = { Date() }
        problem = Self.stop
        isPlaceholder = true
    }

    /// Stops a debug build with `message`. A release build logs it as a fault and goes on.
    static func stop(_ message: String) {
        Log.setup.log(.fault, message)
        assertionFailure(message)
    }

    private func start(_ inputs: DeliveryTriggers.Inputs) {
        let windows = setup?.windows
        triggers = DeliveryTriggers(inputs, retry: { [weak self] in
            Task { await self?.retryNow() }
        }, save: {
            windows?.save()
        })
        requestPass()
    }

    /// Whether the container is watching the app and the network yet. It starts just after it is made.
    var isWatching: Bool { triggers != nil }

    // MARK: - Reports

    /// Checks, seals and queues a report the app sends on its own, such as feedback the person submitted, and
    /// starts sending it in the background.
    ///
    /// - Returns: The report's ID, as Flight Data Recorder will show it.
    /// - Throws: A ``ReportValidationError`` when the report doesn't fit the format; a ``FlightDataError`` when
    ///   the container doesn't take it; and the file system's error when it can't be kept.
    @discardableResult
    public func submit<Report: FlightDataReport>(_ report: Report) async throws -> UUID {
        guard let setup else {
            if isPlaceholder { problem("FlightData: no flightDataContainer(_:) is above this view, so \(Report.self) "
                                       + "wasn’t submitted.") }
            throw FlightDataError.notConfigured
        }
        guard let route = setup.routes[ObjectIdentifier(Report.self)], route.saves == .explicitly else {
            throw FlightDataError.unsupportedReportType(Report.name)
        }
        if route.kind == .telemetry {
            guard consent.isEnabled else { throw FlightDataError.telemetryDisabled }
            if consent.needsErasure { try eraseTelemetry() }
        }
        let prepared = try PreparedReport.make(try report.content(), kind: route.kind, channel: route.name, app: app,
                                               test: setup.test, recipient: route.recipient)
        guard setup.keeps else { return prepared.id }
        try setup.queue.enqueue(prepared, now: now())
        requestPass()
        return prepared.id
    }

    /// Records an event of a periodic type: the first of a period starts it, and each later one is folded into it.
    /// When the period ends, what was gathered is sealed and sent as one report.
    ///
    /// It returns at once and doesn't throw, so it can be called as things happen. Telemetry is ignored while the
    /// person has it turned off. A type that isn't in the schema stops a debug build; an event that can't be
    /// encoded as JSON is dropped and logged.
    public nonisolated func record<Report: PeriodicFlightDataReport>(_ report: Report) {
        guard let setup else {
            if isPlaceholder { problem("FlightData: no flightDataContainer(_:) is above this view, so \(Report.self) "
                                       + "wasn’t recorded.") }
            return
        }
        guard let route = setup.routes[ObjectIdentifier(Report.self)], let period = route.period else {
            problem("FlightData: \(Report.self) isn’t in this container’s schema, so it wasn’t recorded.")
            return
        }
        guard let windows = setup.windows else { return }
        switch windows.record(report, name: route.name, kind: route.kind, period: period, at: now(), consent: consent) {
        case .opened:
            Task { await self.periodicChanged(closed: false) }
        case .closedAndOpened:
            Task { await self.periodicChanged(closed: true) }
        case .merged, .refused:
            break
        case .unencodable:
            Log.periodic.log(.error, "An event of \(route.name) was dropped: it can’t be encoded as JSON.")
        }
    }

    /// How many reports are sealed and waiting to be sent.
    public var pendingCount: Int {
        guard let setup, setup.keeps else { return 0 }
        return setup.queue.listing(at: now()).count
    }

    // MARK: - Telemetry

    /// Whether the person allows telemetry. Feedback and crash reports are sent either way.
    public nonisolated var telemetryEnabled: Bool { consent.isEnabled }

    /// Remembers the person's choice about telemetry, in the kit's own directory, for this and later launches.
    ///
    /// Turning it off erases the telemetry not yet sent, both what is being gathered and what is queued, and
    /// cancels a telemetry upload in progress; a report the server already has can't be recalled. If something
    /// can't be erased at once, telemetry stays off for it and erasing is tried again.
    public func setTelemetryEnabled(_ enabled: Bool) {
        guard consent.setEnabled(enabled), !enabled else { return }
        telemetryUpload?.cancel()
        do { try eraseTelemetry() } catch { requestPass() }
    }

    /// Erases the telemetry gathered and queued before it was turned off. Throws when something couldn't be.
    func eraseTelemetry() throws {
        guard let setup, setup.keeps else { return consent.erasureFinished() }
        do {
            try setup.windows?.discardTelemetry()
            try setup.queue.discardTelemetry()
            consent.erasureFinished()
            Log.telemetry.log(.default, "Telemetry is off: what was gathered and not yet sent was erased.")
        } catch {
            Log.telemetry.log(.error, "Telemetry gathered before it was turned off couldn’t all be erased yet: "
                                      + "\(error.localizedDescription)")
            throw error
        }
    }

    private static func defaultDirectory(appToken: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let key = SHA256.hash(data: Data(appToken.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return support.appending(path: Bundle.main.bundleIdentifier ?? "dev.flightdata.kit")
            .appending(path: "FlightData").appending(path: key)
    }
}
