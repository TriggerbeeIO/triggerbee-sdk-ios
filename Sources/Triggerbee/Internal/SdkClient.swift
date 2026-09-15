import Foundation

/// Holds the configured ``TriggerbeeAPI`` client, the persistent ``SessionStore``, and the
/// in-memory session state. One instance per ``Triggerbee/configure(_:)`` call.
///
/// All public methods are thin wrappers around this actor so the singleton entry point stays
/// small and testable.
actor SdkClient {
    private let config: TriggerbeeConfig
    private let applicationId: String
    private let sessionStore: SessionStore
    private let deviceInfo: DeviceInfo
    private let deviceInfoDto: DeviceInfoDto
    private let api: TriggerbeeAPI

    // sessionStateValue mirrors what's persisted plus in-memory `pageviews` (which intentionally
    // resets on process death — matches the web SDK's sessionStorage semantics).
    private var sessionStateValue: SessionContext = SessionContext(uid: 0, pageviews: 0, identifier: nil)
    private var closedWidgets: [ClosedWidgetEntry] = []
    private var audienceState: VisitorAudienceState = VisitorAudienceState()
    private var initialised = false

    // Multi-subscriber broadcast for sessionContextStream. Each subscribed AsyncStream registers
    // a continuation here; on every state change we yield to all of them. Continuations are
    // pruned on stream cancellation via onTermination.
    private var streamContinuations: [UUID: AsyncStream<SessionContext>.Continuation] = [:]

    var sessionContext: SessionContext { sessionStateValue }

    // `config` is an immutable `let` holding a Sendable value, so the logger is safe to read
    // without hopping onto the actor. Marked nonisolated so the synchronous entry-point
    // helpers (Triggerbee.logger()) can reach it from a non-async context.
    nonisolated var logger: TriggerbeeLogger { config.logger }

    init(
        config: TriggerbeeConfig,
        applicationId: String,
        sessionStore: SessionStore,
        deviceInfo: DeviceInfo,
        urlSession: URLSession? = nil
    ) {
        self.config = config
        self.applicationId = applicationId
        self.sessionStore = sessionStore
        self.deviceInfo = deviceInfo
        self.deviceInfoDto = DeviceInfoDto(
            platform: deviceInfo.platform,
            type: deviceInfo.type,
            osVersion: deviceInfo.osVersion,
            osApiLevel: deviceInfo.osApiLevel,
            sdkVersion: deviceInfo.sdkVersion,
            manufacturer: deviceInfo.manufacturer,
            model: deviceInfo.model,
            appVersion: deviceInfo.appVersion,
            locale: deviceInfo.locale,
            timeZone: deviceInfo.timeZone,
            screenWidth: deviceInfo.screenWidth,
            screenHeight: deviceInfo.screenHeight
        )

        let session: URLSession
        if let urlSession {
            session = urlSession
        } else {
            let sessionConfig = URLSessionConfiguration.ephemeral
            sessionConfig.timeoutIntervalForRequest = config.connectTimeout
            sessionConfig.timeoutIntervalForResource = config.readTimeout
            session = URLSession(configuration: sessionConfig)
        }
        self.api = TriggerbeeAPI(
            baseUrl: config.baseUrl,
            session: session,
            applicationId: applicationId,
            userAgent: config.userAgent,
            logger: config.logger
        )
    }

    // MARK: - Session lifecycle

    func start(generate: () -> Int64) async -> Int64 {
        await ensureLoaded()
        let existing = sessionStateValue.uid
        // Self-heal: treat any non-positive stored uid as missing (an earlier SDK build could
        // persist negative values; the backend rejects uid <= 0). Mints a fresh positive id.
        if existing > 0 {
            config.logger.debug("start: uid=\(existing) (persisted)")
            return existing
        }
        let fresh = generate()
        await sessionStore.setUid(fresh)
        updateSessionState(sessionStateValue.with(uid: fresh))
        config.logger.debug("start: uid=\(fresh) (minted)")
        return fresh
    }

    // MARK: - Pageload / recheck

    func pageload(page: String, title: String, secondsOnPage: Int) async throws -> [WidgetCheckResponse] {
        await ensureLoaded()
        let current = sessionStateValue
        if current.uid == 0 {
            throw TriggerbeeError.notStarted
        }

        let newPageviews = current.pageviews + 1
        updateSessionState(current.with(pageviews: newPageviews))

        let request = PageloadRequest(
            pageview: PageviewDto(path: page, title: title),
            currentVisit: currentVisit(uid: current.uid, page: page, secondsOnPage: secondsOnPage, pageviews: newPageviews),
            closedWidgets: closedWidgets.map(toDto),
            visitorData: visitorData(),
            device: deviceInfoDto
        )
        config.logger.debug("pageload: page=\(page) title=\(title) pageviews=\(newPageviews) secondsOnPage=\(secondsOnPage) \(formatClosedWidgets(closedWidgets))")
        let response: CheckWidgetsResponse
        do {
            response = try await api.pageload(siteId: config.siteId, request: request)
        } catch let error as TriggerbeeError {
            warn("pageload", error: error)
            throw error
        }
        let results = response.toResults()
        config.logger.debug("pageload → \(formatResults(results))")
        return results
    }

    func recheck(page: String, secondsOnPage: Int) async throws -> [WidgetCheckResponse] {
        await ensureLoaded()
        let current = sessionStateValue
        if current.uid == 0 {
            throw TriggerbeeError.notStarted
        }

        let request = CheckRequest(
            currentVisit: currentVisit(uid: current.uid, page: page, secondsOnPage: secondsOnPage, pageviews: current.pageviews),
            closedWidgets: closedWidgets.map(toDto),
            visitorData: visitorData(),
            device: deviceInfoDto
        )
        config.logger.debug("recheck: page=\(page) pageviews=\(current.pageviews) secondsOnPage=\(secondsOnPage) \(formatClosedWidgets(closedWidgets))")
        let response: CheckWidgetsResponse
        do {
            response = try await api.check(siteId: config.siteId, request: request)
        } catch let error as TriggerbeeError {
            warn("recheck", error: error)
            throw error
        }
        let results = response.toResults()
        config.logger.debug("recheck → \(formatResults(results))")
        return results
    }

    // MARK: - Widget close

    func closeWidget(widgetId: Int, reason: CloseReason?) async {
        config.logger.debug("closeWidget: id=\(widgetId) reason=\(reason?.rawValue ?? "nil")")
        await ensureLoaded()
        let entry = ClosedWidgetEntry(
            widgetId: widgetId,
            closedTime: Int64(Date().timeIntervalSince1970 * 1000),
            reason: reason?.rawValue,
            pageviews: sessionStateValue.pageviews
        )
        closedWidgets = closedWidgets.filter { $0.widgetId != widgetId } + [entry]
        await sessionStore.setClosedWidgets(closedWidgets)
        config.logger.debug("closeWidget ✓ \(formatClosedWidgets(closedWidgets))")
    }

    // MARK: - Identify / goals / purchases / pageview / batch

    // The store reads an empty identifier back as nil, so mirroring the raw value into the
    // in-memory context would make the two disagree after a relaunch. Resolve it to what a
    // later read will actually return.
    private static func storedIdentifier(_ identifier: String) -> String? {
        return identifier.isEmpty ? nil : identifier
    }

    func identify(identifier: String, properties: [String: String]) async throws {
        await ensureLoaded()
        let uid = sessionStateValue.uid
        if uid == 0 {
            throw TriggerbeeError.notStarted
        }
        // PII: don't log identifier value (typically email/phone) — only its presence + property count.
        config.logger.debug("identify: hasIdentifier=true properties=\(properties.count)")
        do {
            try await api.identify(
                siteId: config.siteId,
                uid: uid,
                request: IdentifyRequest(identifier: identifier, properties: properties, device: deviceInfoDto)
            )
        } catch let error as TriggerbeeError {
            warn("identify", error: error)
            throw error
        }
        await sessionStore.setIdentifier(identifier)
        updateSessionState(sessionStateValue.with(identifier: SdkClient.storedIdentifier(identifier)))
        config.logger.debug("identify ✓")
    }

    func logGoal(name: String, revenue: String?) async throws {
        await ensureLoaded()
        let uid = sessionStateValue.uid
        if uid == 0 {
            throw TriggerbeeError.notStarted
        }
        config.logger.debug("logGoal: name=\(name) revenue=\(revenue ?? "nil")")
        do {
            try await api.goal(
                siteId: config.siteId,
                uid: uid,
                request: GoalRequest(name: name, revenue: revenue, device: deviceInfoDto)
            )
        } catch let error as TriggerbeeError {
            warn("logGoal", error: error)
            throw error
        }
        // Persist the goal locally so the next pageload/recheck includes it for realtime
        // audience matching, before the server-side Visitors database has caught up.
        if !audienceState.goals.contains(name) {
            audienceState.goals.append(name)
            await sessionStore.setAudienceState(audienceState)
        }
        config.logger.debug("logGoal ✓")
    }

    func logPurchase(revenue: String?, couponCode: String?) async throws {
        await ensureLoaded()
        let uid = sessionStateValue.uid
        if uid == 0 {
            throw TriggerbeeError.notStarted
        }
        config.logger.debug("logPurchase: revenue=\(revenue ?? "nil") couponCode=\(couponCode ?? "nil")")
        do {
            try await api.purchase(
                siteId: config.siteId,
                uid: uid,
                request: PurchaseRequest(revenue: revenue, couponCode: couponCode, device: deviceInfoDto)
            )
        } catch let error as TriggerbeeError {
            warn("logPurchase", error: error)
            throw error
        }
        config.logger.debug("logPurchase ✓")
    }

    func pageview(page: String, title: String) async throws {
        await ensureLoaded()
        let uid = sessionStateValue.uid
        if uid == 0 {
            throw TriggerbeeError.notStarted
        }
        config.logger.debug("pageview: page=\(page) title=\(title)")
        do {
            try await api.pageview(
                siteId: config.siteId,
                uid: uid,
                request: PageviewRequest(path: page, title: title, device: deviceInfoDto)
            )
        } catch let error as TriggerbeeError {
            warn("pageview", error: error)
            throw error
        }
        config.logger.debug("pageview ✓")
    }

    /// Replace the persisted set of landing-page query params. Mobile equivalent of the web
    /// SDK's URL-derived `landingPageQueryParams` — used by audience rules like "came in via
    /// the newsletter campaign". Caller is responsible for parsing a deep-link or
    /// push-notification URL into `key=value` strings and feeding them here.
    func setLandingPageQueryParams(_ params: [String]) async {
        config.logger.debug("setLandingPageQueryParams: count=\(params.count)")
        await ensureLoaded()
        audienceState.landingPageQueryParams = params
        await sessionStore.setAudienceState(audienceState)
        config.logger.debug("setLandingPageQueryParams ✓")
    }

    func batch(
        pageviews: [BatchPageview],
        goals: [BatchGoal],
        purchases: [BatchPurchase],
        identify: BatchIdentify?
    ) async throws {
        await ensureLoaded()
        let uid = sessionStateValue.uid
        if uid == 0 {
            throw TriggerbeeError.notStarted
        }

        let body = BatchRequest(
            pageviews: pageviews.isEmpty ? nil : pageviews.map { BatchPageviewDto(path: $0.path, title: $0.title) },
            goals: goals.isEmpty ? nil : goals.map { BatchGoalDto(name: $0.name, revenue: $0.revenue) },
            purchases: purchases.isEmpty ? nil : purchases.map { BatchPurchaseDto(revenue: $0.revenue, couponCode: $0.couponCode) },
            identify: identify.map { BatchIdentifyDto(identifier: $0.identifier, properties: $0.properties) },
            device: deviceInfoDto
        )

        config.logger.debug(
            "batch: pageviews=\(pageviews.count) goals=\(goals.count) purchases=\(purchases.count) hasIdentify=\(identify != nil)"
        )
        do {
            try await api.batch(siteId: config.siteId, uid: uid, request: body)
        } catch let error as TriggerbeeError {
            warn("batch", error: error)
            throw error
        }

        // Mirror what /identify would do locally so sessionContext stays consistent.
        if let identify {
            await sessionStore.setIdentifier(identify.identifier)
            updateSessionState(sessionStateValue.with(identifier: SdkClient.storedIdentifier(identify.identifier)))
        }
        config.logger.debug("batch ✓")
    }

    // MARK: - Widget URL

    // .urlQueryAllowed permits the sub-delimiters, & and = among them, so encoding a value with
    // it leaves the value able to open new query parameters. Only reachable through an explicit
    // TriggerbeeConfig(applicationId:) — a bundle identifier cannot contain these — but the
    // encoding should be correct for whatever it is handed. Android already encodes properly.
    private static let queryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#;,/:$")
        return allowed
    }()

    nonisolated func widgetUrl(widgetId: Int, uid: Int64) -> String {
        // Non-throwing by design — the result feeds straight into a WebView load — so the
        // uid == 0 case is handled by Triggerbee.widgetUrl(widgetId:) before we get here: it
        // logs and returns "" rather than trapping the host process. URLs are percent-encoded
        // inline because we don't want to depend on URLComponents allocating per call.
        let encodedAppId = applicationId.addingPercentEncoding(withAllowedCharacters: SdkClient.queryValueAllowed) ?? applicationId
        let url = "\(config.baseUrl)/v2/client/widgets/\(widgetId)/html" +
            "?siteId=\(config.siteId)&uid=\(uid)&applicationId=\(encodedAppId)" +
            "&targetDevice=NativeApp"
        config.logger.debug("widgetUrl: id=\(widgetId) → \(url)")
        return url
    }

    // Base URL of the configured Triggerbee gateway (e.g. https://api.triggerbee.com). Exposed so
    // the prefetch document has a real origin for its <link rel=preload> to resolve against.
    nonisolated var baseUrl: String { config.baseUrl }

    // URLs of the two <script async> resources embedded by /v2/client/widgets/{id}/html.
    // Same per-site content across visitors — safe for the SDK to prefetch into the WKWebView's
    // shared HTTP cache. The widget HTML itself is per-visitor (uid varies) so we don't prefetch it.
    nonisolated func trackingScriptUrl() -> String {
        let encodedAppId = applicationId.addingPercentEncoding(withAllowedCharacters: SdkClient.queryValueAllowed) ?? applicationId
        return "\(config.baseUrl)/v2/client/scripts/core?siteId=\(config.siteId)" +
            "&targetDevice=NativeApp&applicationId=\(encodedAppId)"
    }

    nonisolated func siteScriptUrl() -> String {
        let encodedAppId = applicationId.addingPercentEncoding(withAllowedCharacters: SdkClient.queryValueAllowed) ?? applicationId
        return "\(config.baseUrl)/v2/client/scripts/site?siteId=\(config.siteId)" +
            "&targetDevice=NativeApp&applicationId=\(encodedAppId)"
    }

    // MARK: - SessionContext stream

    /// Build a new ``AsyncStream`` that emits the current state immediately and yields every
    /// subsequent update until the consumer cancels iteration (the stream's task is cancelled
    /// or the for-await loop completes). The internal continuation registry self-prunes on
    /// termination so leaked streams don't accumulate.
    func makeSessionContextStream() -> AsyncStream<SessionContext> {
        var capturedContinuation: AsyncStream<SessionContext>.Continuation?
        let stream = AsyncStream<SessionContext> { continuation in
            capturedContinuation = continuation
        }
        guard let continuation = capturedContinuation else { return stream }
        let id = UUID()
        streamContinuations[id] = continuation
        continuation.yield(sessionStateValue)
        continuation.onTermination = { [weak self] _ in
            // Hop back into the actor to mutate the dictionary.
            Task { await self?.removeContinuation(id: id) }
        }
        return stream
    }

    private func removeContinuation(id: UUID) {
        streamContinuations.removeValue(forKey: id)
    }

    // MARK: - Private helpers

    /// Initial load happens lazily so concurrent first calls don't race UserDefaults reads.
    /// After the first successful load `initialised` stays true.
    private func ensureLoaded() async {
        if initialised { return }
        let uid = await sessionStore.getUid() ?? 0
        let identifier = await sessionStore.getIdentifier()
        closedWidgets = await sessionStore.getClosedWidgets()
        audienceState = await sessionStore.getAudienceState()
        sessionStateValue = SessionContext(uid: uid, pageviews: 0, identifier: identifier)
        initialised = true
        config.logger.debug("DataStore loaded: uid=\(uid) identifier=\(identifier ?? "nil") \(formatClosedWidgets(closedWidgets))")
        broadcast()
    }

    private func updateSessionState(_ next: SessionContext) {
        sessionStateValue = next
        broadcast()
    }

    private func broadcast() {
        for (_, cont) in streamContinuations {
            cont.yield(sessionStateValue)
        }
    }

    /// Snapshot of identifier + audience state for the next outgoing widget-check request.
    private func visitorData() -> VisitorData {
        return VisitorData(
            identifier: sessionStateValue.identifier,
            goals: audienceState.goals,
            landingPageQueryParams: audienceState.landingPageQueryParams
        )
    }

    private func currentVisit(uid: Int64, page: String, secondsOnPage: Int, pageviews: Int) -> CurrentVisit {
        return CurrentVisit(
            uid: uid,
            page: page,
            secondsOnPage: secondsOnPage,
            pageviews: pageviews,
            usersTime: Self.localDateTimeFormatter.string(from: Date()),
            ipAddress: nil
        )
    }

    private func toDto(_ entry: ClosedWidgetEntry) -> ClosedWidget {
        return ClosedWidget(
            widgetId: entry.widgetId,
            closedTime: entry.closedTime,
            reason: entry.reason,
            pageviews: entry.pageviews
        )
    }

    private func formatResults(_ results: [WidgetCheckResponse]) -> String {
        let inner = results.map { "id=\($0.id) result=\($0.result) openDelay=\($0.openDelay)" }.joined(separator: ", ")
        return "\(results.count) widgets [\(inner)]"
    }

    private func formatClosedWidgets(_ entries: [ClosedWidgetEntry]) -> String {
        let inner = entries.map { "id=\($0.widgetId) reason=\($0.reason ?? "nil") pageviews=\($0.pageviews) closedTime=\($0.closedTime)" }.joined(separator: ", ")
        return "\(entries.count) closedWidgets [\(inner)]"
    }

    private func warn(_ operation: String, error: TriggerbeeError) {
        switch error {
        case .httpError(let code, let body):
            config.logger.warn("\(operation) failed: HTTP \(code) — \(body)")
        case .networkError(let cause):
            config.logger.warn("\(operation) network error: \(type(of: cause)): \(cause.localizedDescription)", error: cause)
        case .serializationError(let cause):
            config.logger.warn("\(operation) serialization error: \(type(of: cause)): \(cause.localizedDescription)", error: cause)
        case .notInitialized:
            config.logger.warn("\(operation) called on uninitialized SDK")
        case .notStarted:
            config.logger.warn("\(operation) called before Triggerbee.start()")
        }
    }

    /// Visitor wall-clock; matches what mytracker.js sends from a real browser
    /// (yyyy-MM-dd'T'HH:mm:ss, no timezone — server treats it as the visitor's local time).
    private static let localDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

private extension CheckWidgetsResponse {
    func toResults() -> [WidgetCheckResponse] {
        return widgets.map {
            WidgetCheckResponse(id: $0.id, result: $0.result, openDelay: $0.openDelay)
        }
    }
}

private extension SessionContext {
    func with(uid: Int64) -> SessionContext {
        return SessionContext(uid: uid, pageviews: pageviews, identifier: identifier)
    }

    func with(pageviews: Int) -> SessionContext {
        return SessionContext(uid: uid, pageviews: pageviews, identifier: identifier)
    }

    func with(identifier: String?) -> SessionContext {
        return SessionContext(uid: uid, pageviews: pageviews, identifier: identifier)
    }
}
