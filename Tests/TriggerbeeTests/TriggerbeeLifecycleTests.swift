import XCTest
@testable import Triggerbee

/// Tests for the misuse and re-configuration paths.
///
/// The SDK used to answer these with `precondition` / `preconditionFailure`, which traps and
/// kills the host process in a release build. Android raises catchable exceptions from
/// `require()`, so these paths now log-and-degrade or throw. Every assertion here would have
/// been a crash before.
final class TriggerbeeLifecycleTests: XCTestCase {

    private var server: MockHTTPServer!
    private var logger: CapturingLogger!

    override func setUp() async throws {
        try await super.setUp()
        server = try MockHTTPServer()
        logger = CapturingLogger()
        Triggerbee.shared.enable()
    }

    override func tearDown() async throws {
        Triggerbee.shared.enable()
        await server.stop()
        server = nil
        logger = nil
        try await super.tearDown()
    }

    private func configure(store: SessionStore = InMemorySessionStore()) {
        let config = TriggerbeeConfig(siteId: 12345, baseUrl: server.baseUrl, logger: logger)
        Triggerbee.shared.configureForTesting(config, sessionStore: store, urlSession: server.urlSession)
    }

    // MARK: - Misuse before start()

    func testWidgetUrlBeforeStartReturnsEmptyStringAndLogs() {
        // Arrange — configured, but start() never called, so there is no uid yet.
        configure()

        // Act
        let url = Triggerbee.shared.widgetUrl(widgetId: 42)

        // Assert — an empty URL, not a trapped process.
        XCTAssertEqual(url, "")
        XCTAssertTrue(logger.logged("before start()"))
    }

    func testPageloadBeforeStartThrowsNotStarted() async {
        // Arrange
        configure()

        // Act / Assert
        do {
            _ = try await Triggerbee.shared.pageload(page: "/home", title: "Home")
            XCTFail("expected pageload to throw .notStarted")
        } catch let error as TriggerbeeError {
            guard case .notStarted = error else {
                return XCTFail("expected .notStarted, got \(error)")
            }
        } catch {
            XCTFail("expected TriggerbeeError, got \(error)")
        }
        XCTAssertEqual(server.requestCount, 0, "no request should be sent without a uid")
    }

    func testSessionContextBeforeStartIsEmptyAndDoesNotBlock() {
        // Arrange
        configure()

        // Act — this is the read that used to block on a DispatchSemaphore.
        let context = Triggerbee.shared.sessionContext

        // Assert
        XCTAssertEqual(context.uid, 0)
        XCTAssertNil(context.identifier)
    }

    // MARK: - The cache the synchronous getter reads

    func testStartMirrorsUidIntoSynchronousSessionContext() async {
        // Arrange
        configure()

        // Act
        let uid = await Triggerbee.shared.start()

        // Assert — start() must leave the sync getter warm; widgetUrl depends on it.
        XCTAssertNotEqual(uid, 0)
        XCTAssertEqual(Triggerbee.shared.sessionContext.uid, uid)
        XCTAssertTrue(Triggerbee.shared.widgetUrl(widgetId: 42).contains("uid=\(uid)"))
    }

    func testReconfiguringDropsTheStaleUid() async {
        // Arrange — configure, start, and confirm the cache is warm.
        configure()
        let firstUid = await Triggerbee.shared.start()
        XCTAssertEqual(Triggerbee.shared.sessionContext.uid, firstUid)

        // Act — reconfigure with a fresh store, which has no uid in it.
        configure(store: InMemorySessionStore())

        // Assert — the previous client's uid must not survive into the new configuration.
        XCTAssertEqual(Triggerbee.shared.sessionContext.uid, 0)
        XCTAssertEqual(Triggerbee.shared.widgetUrl(widgetId: 42), "")
    }

    // MARK: - Configuration validation

    func testTrailingSlashIsStrippedFromBaseUrl() {
        let config = TriggerbeeConfig(siteId: 1, baseUrl: "https://api.triggerbee.com/")
        XCTAssertEqual(config.baseUrl, "https://api.triggerbee.com")
    }

    func testNonPositiveSiteIdIsRejectedWithoutCrashing() {
        // Arrange
        let rejectingLogger = CapturingLogger()

        // Act — this used to be a precondition failure inside TriggerbeeConfig.init.
        Triggerbee.shared.configure(TriggerbeeConfig(siteId: 0, logger: rejectingLogger))

        // Assert
        XCTAssertTrue(rejectingLogger.logged("siteId must be > 0"))
    }

    func testRejectedConfigureLeavesAWorkingConfigurationIntact() async throws {
        // Arrange — a valid configuration, started.
        configure()
        _ = await Triggerbee.shared.start()
        server.enqueue(status: 200, body: #"{"widgets":[]}"#)

        // Act — a bad configure() must not tear down the working one.
        Triggerbee.shared.configure(TriggerbeeConfig(siteId: -1, logger: CapturingLogger()))

        // Assert — still talking to the mock server.
        _ = try await Triggerbee.shared.pageload(page: "/home", title: "Home")
        XCTAssertGreaterThanOrEqual(server.requestCount, 1)
    }
}

/// Guards the JS bridge's wire format.
///
/// The widget engine (`native-app-service.ts`) posts flat payloads —
/// `{method:"setBounds", width, height, position, layout}`. The SDK originally read the fields
/// from a nested `args` dictionary, so every bridge call from a real widget was dropped: bounds
/// never arrived, the 3-second safeguard fired, and every widget closed itself. Production is
/// the only place that showed it, because a mock written against the SDK's own assumption
/// agrees with the bug.
final class WidgetBridgePayloadTests: XCTestCase {

    /// Mirrors the resolution step in TriggerbeeWebViewCoordinator.userContentController.
    private func resolveArgs(_ payload: [String: Any]) -> [String: Any] {
        return (payload["args"] as? [String: Any]) ?? payload
    }

    func testFlatSetBoundsPayloadIsParsed() {
        // Exactly what postToIos sends.
        let payload: [String: Any] = [
            "method": "setBounds", "width": 320, "height": 200,
            "position": "Center", "layout": "Popup",
        ]
        let args = resolveArgs(payload)
        XCTAssertEqual((args["width"] as? NSNumber)?.intValue, 320)
        XCTAssertEqual((args["height"] as? NSNumber)?.intValue, 200)
        XCTAssertEqual(WidgetPosition.from(args["position"] as? String), .center)
        XCTAssertEqual(WidgetLayout.from(args["layout"] as? String), .popup)
    }

    func testNestedArgsPayloadStillParses() {
        // Kept working in case the engine ever adopts an envelope.
        let payload: [String: Any] = [
            "method": "setBounds",
            "args": ["width": 480, "height": 640, "position": "Bottom", "layout": "Panel"],
        ]
        let args = resolveArgs(payload)
        XCTAssertEqual((args["width"] as? NSNumber)?.intValue, 480)
        XCTAssertEqual(WidgetPosition.from(args["position"] as? String), .bottom)
        XCTAssertEqual(WidgetLayout.from(args["layout"] as? String), .panel)
    }

    func testFlatUpdateAndNavigatePayloadsAreParsed() {
        XCTAssertEqual(resolveArgs(["method": "update", "reason": "Dismissal"])["reason"] as? String, "Dismissal")
        XCTAssertEqual(resolveArgs(["method": "navigate", "url": "https://example.com"])["url"] as? String, "https://example.com")
        XCTAssertEqual(resolveArgs(["method": "failed", "reason": "engine error"])["reason"] as? String, "engine error")
    }

    /// A flat setBounds must not be mistaken for a zero-sized one — that was the actual failure
    /// mode: width/height fell back to 0, so no bounds were ever applied.
    func testFlatPayloadDoesNotDegradeToZeroBounds() {
        let args = resolveArgs(["method": "setBounds", "width": 320, "height": 200])
        XCTAssertNotEqual((args["width"] as? NSNumber)?.intValue ?? 0, 0)
        XCTAssertNotEqual((args["height"] as? NSNumber)?.intValue ?? 0, 0)
    }
}

/// Guards MockHTTPServer's isolation between instances.
///
/// The queues used to live in `static` storage, safe only because tests run serially. Enabling
/// parallel execution would have made two live servers steal each other's queued responses.
final class MockHTTPServerIsolationTests: XCTestCase {

    func testTwoLiveServersDoNotShareQueuesOrRequestCounts() async throws {
        let a = try MockHTTPServer()
        let b = try MockHTTPServer()
        defer { Task { await a.stop(); await b.stop() } }

        XCTAssertNotEqual(a.baseUrl, b.baseUrl, "each server must claim its own host")

        // Distinguishable responses queued on each.
        a.enqueue(status: 200, body: #"{"widgets":[{"id":11,"result":true,"openDelay":0}]}"#)
        b.enqueue(status: 200, body: #"{"widgets":[{"id":22,"result":true,"openDelay":0}]}"#)

        // Drive only server A.
        Triggerbee.shared.configureForTesting(
            TriggerbeeConfig(siteId: 1, baseUrl: a.baseUrl),
            sessionStore: InMemorySessionStore(),
            urlSession: a.urlSession
        )
        _ = await Triggerbee.shared.start()
        let widgets = try await Triggerbee.shared.pageload(page: "/a", title: "A")

        XCTAssertEqual(widgets.first?.id, 11, "A must serve its own queued response")
        XCTAssertGreaterThanOrEqual(a.requestCount, 1)
        XCTAssertEqual(b.requestCount, 0, "B must not see traffic aimed at A")
        XCTAssertNil(b.lastRequest())
    }

    func testAStoppedServerNoLongerInterceptsItsHost() async throws {
        let server = try MockHTTPServer()
        let baseUrl = server.baseUrl
        server.enqueue(status: 200, body: #"{"widgets":[]}"#)
        await server.stop()

        // With the server deregistered, the stub must decline the request rather than answering
        // from a stale queue — surfacing as a network error.
        Triggerbee.shared.configureForTesting(
            TriggerbeeConfig(siteId: 1, baseUrl: baseUrl),
            sessionStore: InMemorySessionStore(),
            urlSession: URLSession(configuration: .ephemeral)
        )
        _ = await Triggerbee.shared.start()
        do {
            _ = try await Triggerbee.shared.pageload(page: "/gone", title: "Gone")
            XCTFail("expected the request to fail once the server stopped")
        } catch let error as TriggerbeeError {
            guard case .networkError = error else {
                return XCTFail("expected .networkError, got \(error)")
            }
        }
    }
}
