import Foundation
#if canImport(WebKit) && (os(iOS) || os(macOS) || os(tvOS))
import WebKit
#endif

/// Single entry point to the Triggerbee SDK. Call ``configure(_:)`` once during app startup,
/// then use the async methods from any context.
///
/// ```swift
/// // App init / AppDelegate.application(_:didFinishLaunchingWithOptions:)
/// Triggerbee.shared.configure(TriggerbeeConfig(siteId: YOUR_SITE_ID))
///
/// // Anywhere later
/// Task {
///     await Triggerbee.shared.start()
///     let widgets = try await Triggerbee.shared.pageload(page: "/profile", title: "Profile")
///     if let hit = widgets.first(where: { $0.result }) {
///         openWebView(url: Triggerbee.shared.widgetUrl(widgetId: hit.id))
///     }
/// }
/// ```
public final class Triggerbee: @unchecked Sendable {
    /// Process-wide singleton. Mirrors the static-singleton ergonomics of the Android SDK.
    public static let shared = Triggerbee()

    private init() {}

    // The lock guards configuration + disable state. SdkClient itself is an actor and
    // serializes its own internal state.
    private let lock = NSLock()
    private var client: SdkClient?
    private var disabledFlag: Bool = false

    // In-process dedup set for "this widget has already had its `open` event logged this visit".
    // Native equivalent of the web tracker's sessionStorage `mtr_v.viewedWidgetIds` — same
    // semantic (one open-log per visit, where visit = app process lifetime here vs browser tab on
    // web). Scoped to the `open` event only; close/clickthrough/etc. always log.
    private var openLoggedWidgetIds: Set<Int> = []

    /// Configure the SDK. Call once, typically in your app's `init` or
    /// `application(_:didFinishLaunchingWithOptions:)`. Calling a second time replaces the
    /// configuration (useful for tests; avoid in production code).
    ///
    /// Also kicks off a one-time WKWebView warmup on the main queue: the first WKWebView in an
    /// app process pays a startup cost for the WebKit renderer process spin-up. Doing that once
    /// at configure time means the widget WebView opens with a warm process.
    ///
    /// An invalid configuration (non-positive `siteId`, empty `baseUrl`) is rejected with a
    /// logged error rather than a crash. Any previously applied configuration is left intact —
    /// a bad call can't tear down a working SDK — so if this was the first `configure(_:)` call
    /// the SDK stays unconfigured and subsequent methods throw ``TriggerbeeError/notInitialized``.
    /// Pass ``OSLogger`` while integrating so that error is visible in Console.app rather than
    /// silent.
    public func configure(_ config: TriggerbeeConfig) {
        guard config.siteId > 0 else {
            config.logger.error("configure(_:) rejected — siteId must be > 0, got \(config.siteId). Configuration unchanged.")
            return
        }
        guard !config.baseUrl.isEmpty else {
            config.logger.error("configure(_:) rejected — baseUrl must not be empty. Configuration unchanged.")
            return
        }
        let applicationId = config.applicationId ?? (Bundle.main.bundleIdentifier ?? "unknown.bundle")
        let sessionStore = UserDefaultsSessionStore()
        let deviceInfo = DeviceInfoCollector.collect()
        let client = SdkClient(
            config: config,
            applicationId: applicationId,
            sessionStore: sessionStore,
            deviceInfo: deviceInfo
        )
        lock.withLock {
            self.client = client
            self.resetDerivedCachesLocked()
        }
        warmupWebView()
    }

    // MARK: - WebView warmup + script prefetch

    #if canImport(WebKit) && (os(iOS) || os(macOS) || os(tvOS))
    // Held for the process lifetime so WebKit's renderer process stays alive between the
    // warmup load and the first real widget open. If we let this get deallocated the renderer
    // can be reaped and the next widget open pays cold-start again.
    private var warmupWebViewInstance: WKWebView?

    // Once-per-process guard so we don't reload the prefetch document every pageload; the two
    // script responses are per-site (not per-widget or per-visitor), so a single populate of
    // the WKWebView's shared HTTP cache serves every widget open for the rest of the process.
    private var scriptsPrefetched: Bool = false

    private func warmupWebView() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let shouldStart = self.lock.withLock { () -> Bool in
                if self.warmupWebViewInstance != nil { return false }
                let wv = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
                if let url = URL(string: "about:blank") {
                    wv.load(URLRequest(url: url))
                }
                self.warmupWebViewInstance = wv
                return true
            }
            if shouldStart {
                self.logger().debug("WebView warmup started")
            }
        }
    }

    /// Prime the WKWebView's shared HTTP cache with the two <script async> resources embedded
    /// by /v2/client/widgets/{id}/html. Called automatically from `pageload`/`recheck` whenever
    /// a matching widget is returned, so by the time the host app mounts `TriggerbeeWidgetView`
    /// the scripts are already in cache and Phase 2→4 skips their network round-trips.
    ///
    /// Loads a tiny prefetch document into the same WKWebView instance kept warm by
    /// `warmupWebView` — WKWebView instances share HTTP cache within an app process, so
    /// populating it from any WebView benefits every subsequent one.
    fileprivate func prefetchScripts() async {
        let shouldPrefetch: Bool = lock.withLock {
            if scriptsPrefetched { return false }
            scriptsPrefetched = true
            return true
        }
        guard shouldPrefetch else { return }
        guard let client = currentClient() else {
            lock.withLock { scriptsPrefetched = false }
            return
        }
        // All three are nonisolated on SdkClient — no actor hop, no await needed.
        let trackingUrl = client.trackingScriptUrl()
        let siteUrl = client.siteScriptUrl()
        let baseUrlString = client.baseUrl
        await MainActor.run { [weak self] in
            guard let self else { return }
            guard let warmup = self.lock.withLock({ self.warmupWebViewInstance }) else {
                self.lock.withLock { self.scriptsPrefetched = false }
                return
            }
            let html = "<html><head>" +
                "<link rel=\"preload\" as=\"script\" href=\"\(trackingUrl)\"/>" +
                "<link rel=\"preload\" as=\"script\" href=\"\(siteUrl)\"/>" +
                "</head><body></body></html>"
            warmup.loadHTMLString(html, baseURL: URL(string: baseUrlString))
            self.logger().debug("prefetchScripts started")
        }
    }
    #else
    // No-op on platforms without WebKit (e.g. Linux Swift). Widget rendering isn't available
    // there either, so tracking API calls still work but WebView-related helpers are absent.
    private func warmupWebView() {}
    fileprivate func prefetchScripts() async {}
    #endif

    /// Test-only configuration hook that lets a test supply its own ``SessionStore`` and
    /// optional `URLSession` for HTTP stubbing. Internal so production callers can't reach
    /// for it; tests that link via @testable can.
    func configureForTesting(_ config: TriggerbeeConfig, sessionStore: SessionStore, urlSession: URLSession? = nil) {
        let applicationId = config.applicationId ?? "com.triggerbee.test"
        let deviceInfo = DeviceInfoCollector.collect()
        let client = SdkClient(
            config: config,
            applicationId: applicationId,
            sessionStore: sessionStore,
            deviceInfo: deviceInfo,
            urlSession: urlSession
        )
        lock.withLock {
            self.client = client
            self.resetDerivedCachesLocked()
        }
    }

    /// Drop every cache derived from the previous ``SdkClient``. Caller must already hold `lock`.
    ///
    /// Without this, replacing the client (which ``configure(_:)`` explicitly permits) leaves a
    /// stale uid behind for `widgetUrl(widgetId:)` to hand out, and suppresses the `open` event
    /// for a widget the new configuration has never seen.
    private func resetDerivedCachesLocked() {
        cachedSessionContext = nil
        openLoggedWidgetIds = []
        #if canImport(WebKit) && (os(iOS) || os(macOS) || os(tvOS))
        scriptsPrefetched = false
        #endif
    }

    /// Opt the visitor out of all Triggerbee tracking for the rest of the process lifetime.
    /// After this call every public method becomes a silent no-op (async methods return
    /// immediately, `pageload`/`recheck` return an empty array, `widgetUrl` returns an empty
    /// string) and no network requests are made.
    public func disable() {
        lock.withLock { disabledFlag = true }
    }

    /// Re-enable tracking after a prior ``disable()`` call. Idempotent.
    public func enable() {
        lock.withLock { disabledFlag = false }
    }

    /// `true` once ``disable()`` has been called; flips back to `false` after ``enable()``.
    public var isDisabled: Bool {
        return lock.withLock { disabledFlag }
    }

    /// Generate and persist a visitor id (uid) on first launch; reuse the existing id on
    /// subsequent launches. Idempotent — safe to call every app start.
    ///
    /// The id is generated client-side via `SystemRandomNumberGenerator` (non-zero, uniformly
    /// distributed over `[1, 2^53 - 1]` — capped to the JavaScript `Number.MAX_SAFE_INTEGER`
    /// so the value survives the WebView's `parseInt(cookie)` round-trip in mytracker.js
    /// without IEEE 754 precision loss).
    @discardableResult
    public func start() async -> Int64 {
        if isDisabled { return 0 }
        guard let client = currentClient() else { return 0 }
        let uid = await client.start(generate: Triggerbee.generateUid)
        await mirrorSessionContext(from: client)
        return uid
    }

    /// Log a pageview and get the widgets that should be considered for display on this page.
    public func pageload(page: String, title: String, secondsOnPage: Int = 0) async throws -> [WidgetCheckResponse] {
        if isDisabled { return [] }
        let client = try require()
        let results = try await client.pageload(page: page, title: title, secondsOnPage: secondsOnPage)
        await mirrorSessionContext(from: client)
        // Prime the WebView cache while the caller is still on Main, before it can mount
        // TriggerbeeWidgetView and start a real widget load. Once-per-process guarded internally.
        if results.contains(where: { $0.result }) { await prefetchScripts() }
        return results
    }

    /// Re-evaluate widgets for the current page without logging a new pageview. Use after
    /// waiting out an `openDelay` returned from ``pageload(page:title:secondsOnPage:)``.
    public func recheck(page: String, secondsOnPage: Int) async throws -> [WidgetCheckResponse] {
        if isDisabled { return [] }
        let client = try require()
        let results = try await client.recheck(page: page, secondsOnPage: secondsOnPage)
        await mirrorSessionContext(from: client)
        if results.contains(where: { $0.result }) { await prefetchScripts() }
        return results
    }

    /// Mark a widget closed locally; sent on the next pageload/recheck so the backend can
    /// apply the matching repetition rule.
    public func closeWidget(widgetId: Int, reason: CloseReason? = nil) {
        if isDisabled { return }
        guard let client = currentClient() else { return }
        // Fire-and-forget so the public API stays sync — mirrors Android's closeWidget contract.
        Task {
            await client.closeWidget(widgetId: widgetId, reason: reason)
            await self.mirrorSessionContext(from: client)
        }
    }

    /// Identify a visitor with custom properties. Optionally with an identifier (e.g. email).
    public func identify(_ identifier: String, properties: [String: String] = [:]) async throws {
        if isDisabled { return }
        let client = try require()
        try await client.identify(identifier: identifier, properties: properties)
        await mirrorSessionContext(from: client)
    }

    /// Log a custom goal. `revenue` is a string so the caller controls formatting (e.g. "199.00").
    /// The goal name is also persisted locally and replayed on the next pageload / recheck so
    /// audience rules can match in realtime — before the goal lands in the Visitors database.
    public func logGoal(name: String, revenue: String? = nil) async throws {
        if isDisabled { return }
        let client = try require()
        try await client.logGoal(name: name, revenue: revenue)
        await mirrorSessionContext(from: client)
    }

    /// Log a purchase. `revenue` is a string so the caller controls formatting (e.g. "199.00").
    /// Hits `POST /v2/client/events/{uid}/purchase`.
    public func logPurchase(revenue: String? = nil, couponCode: String? = nil) async throws {
        if isDisabled { return }
        let client = try require()
        try await client.logPurchase(revenue: revenue, couponCode: couponCode)
        await mirrorSessionContext(from: client)
    }

    /// Log a pageview event without checking widgets. Use this when you only want to record
    /// that the visitor saw a page (e.g. for analytics / audience matching) but don't need
    /// the widgets — for that, use ``pageload(page:title:secondsOnPage:)`` instead.
    public func pageview(page: String, title: String) async throws {
        if isDisabled { return }
        let client = try require()
        try await client.pageview(page: page, title: title)
        await mirrorSessionContext(from: client)
    }

    /// Replace the persisted set of landing-page query params. Audience rules like
    /// "came in via the newsletter campaign" check against these. Caller is responsible for
    /// parsing the incoming deep link / push-notification URL.
    public func setLandingPageQueryParams(_ params: [String]) async {
        if isDisabled { return }
        guard let client = currentClient() else { return }
        await client.setLandingPageQueryParams(params)
        await mirrorSessionContext(from: client)
    }

    /// Log multiple events for the current visitor in a single round-trip. Each list is
    /// independently optional — call with only the groups you actually have.
    public func batch(
        pageviews: [BatchPageview] = [],
        goals: [BatchGoal] = [],
        purchases: [BatchPurchase] = [],
        identify: BatchIdentify? = nil
    ) async throws {
        if isDisabled { return }
        let client = try require()
        try await client.batch(pageviews: pageviews, goals: goals, purchases: purchases, identify: identify)
        await mirrorSessionContext(from: client)
    }

    /// Build the URL for a widget's rendered HTML — feed this into a `WKWebView` load. The
    /// URL carries `uid` and `applicationId` so Tracker can authenticate the WebView's
    /// tracking calls against the account's AllowedApplicationIds.
    public func widgetUrl(widgetId: Int) -> String {
        if isDisabled { return "" }
        guard let client = currentClient() else { return "" }
        // The uid is read synchronously from the mirrored session cache — see sessionContext.
        let uid = currentUidSync()
        if uid == 0 {
            // An earlier version called preconditionFailure here "to match Android". It didn't:
            // Kotlin's require() throws a catchable IllegalArgumentException, while Swift's
            // precondition traps and kills the host process in a release build. A third-party
            // SDK must never do that, so this logs and returns "" — the same contract as the
            // disabled case above, and TriggerbeeWidgetView already routes an unparseable URL
            // through its onLoadFailed path.
            logger().error("widgetUrl(widgetId:) called before start() completed — returning an empty URL")
            return ""
        }
        return client.widgetUrl(widgetId: widgetId, uid: uid)
    }

    /// Snapshot of the current session state. Synchronously readable. Reflects the most recent
    /// write performed by the SDK; the matching ``sessionContextStream`` yields updates.
    public var sessionContext: SessionContext {
        // Every async public method mirrors the actor's state into `cachedSessionContext` as
        // it completes (see mirrorSessionContext(from:)), so this read is served from the cache
        // and never blocks a caller's thread.
        if let cached = lock.withLock({ cachedSessionContext }) { return cached }
        guard currentClient() != nil else {
            return SessionContext(uid: 0, pageviews: 0, identifier: nil)
        }
        return unstartedSessionContext()
    }

    /// Hot stream of session state. Yields the current value immediately on subscribe and
    /// every subsequent update until the consumer's task is cancelled.
    ///
    /// ```swift
    /// Task {
    ///     for await ctx in Triggerbee.shared.sessionContextStream {
    ///         print("uid=\(ctx.uid) identifier=\(ctx.identifier ?? "nil")")
    ///     }
    /// }
    /// ```
    public var sessionContextStream: AsyncStream<SessionContext> {
        guard let client = currentClient() else {
            return AsyncStream { continuation in continuation.finish() }
        }
        // Spawn a task to bridge the actor-isolated stream-construction. Returning a stream
        // that delegates to the actor stream means consumers see the same yields.
        let (stream, continuation) = Self.makePassthroughStream()
        Task { [weak self] in
            let inner = await client.makeSessionContextStream()
            for await value in inner {
                self?.lock.withLock { self?.cachedSessionContext = value }
                continuation.yield(value)
            }
            continuation.finish()
        }
        return stream
    }

    // MARK: - Internal helpers

    /// Returns the active SdkClient or nil if ``configure(_:)`` hasn't been called.
    func currentClient() -> SdkClient? {
        return lock.withLock { client }
    }

    func logger() -> TriggerbeeLogger {
        return currentClient()?.logger ?? NoOpLogger()
    }

    func hasLoggedOpen(_ id: Int) -> Bool {
        return lock.withLock { openLoggedWidgetIds.contains(id) }
    }

    func markOpenLogged(_ id: Int) {
        lock.withLock { _ = openLoggedWidgetIds.insert(id) }
    }

    private var cachedSessionContext: SessionContext?

    /// Copy the actor's session state into the cache that the synchronous ``sessionContext``
    /// getter reads. Called at the end of every state-mutating public method, which is what
    /// makes that getter both synchronous and non-blocking.
    private func mirrorSessionContext(from client: SdkClient) async {
        let snapshot = await client.sessionContext
        lock.withLock { cachedSessionContext = snapshot }
    }

    /// Fallback for a synchronous session read that lands before any async SDK call has warmed
    /// the cache — i.e. before `start()` has completed.
    ///
    /// This deliberately does **not** block. The previous implementation bridged into the actor
    /// with `DispatchSemaphore.wait()`, and because `widgetUrl(widgetId:)` reaches this path
    /// from `TriggerbeeWidgetView.buildWebView` on the main actor, that was a main-thread stall
    /// on the SDK's primary integration flow — not an edge case, since nothing warmed the cache
    /// beforehand.
    private func unstartedSessionContext() -> SessionContext {
        logger().warn("sessionContext read before start() completed — returning an empty context")
        return SessionContext(uid: 0, pageviews: 0, identifier: nil)
    }

    private func currentUidSync() -> Int64 {
        return sessionContext.uid
    }

    private static func makePassthroughStream() -> (AsyncStream<SessionContext>, AsyncStream<SessionContext>.Continuation) {
        var capturedContinuation: AsyncStream<SessionContext>.Continuation?
        let stream = AsyncStream<SessionContext> { continuation in
            capturedContinuation = continuation
        }
        return (stream, capturedContinuation!)
    }

    private func require() throws -> SdkClient {
        guard let client = currentClient() else {
            throw TriggerbeeError.notInitialized
        }
        return client
    }

    /// Positive 53-bit visitor id, never zero. Capped at JavaScript `Number.MAX_SAFE_INTEGER`
    /// so the value survives the WebView's `parseInt(cookie)` round-trip in mytracker.js
    /// without IEEE 754 precision loss.
    static func generateUid() -> Int64 {
        var rng = SystemRandomNumberGenerator()
        let cap: UInt64 = (1 << 53) - 1
        var value: UInt64 = 0
        while value == 0 {
            value = rng.next() & cap
        }
        return Int64(value)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
