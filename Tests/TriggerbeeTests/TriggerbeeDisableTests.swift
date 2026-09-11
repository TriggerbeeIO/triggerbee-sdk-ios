import XCTest
@testable import Triggerbee

/// End-to-end behaviour tests for ``Triggerbee/disable()``: with the kill-switch on, every
/// public method must short-circuit and avoid hitting the network. Mirrors the Android SDK's
/// `TriggerbeeDisableTest`.
final class TriggerbeeDisableTests: XCTestCase {

    private var server: MockHTTPServer!

    override func setUp() async throws {
        try await super.setUp()
        server = try MockHTTPServer()
        let config = TriggerbeeConfig(siteId: 12345, baseUrl: server.baseUrl)
        Triggerbee.shared.configureForTesting(config, sessionStore: InMemorySessionStore(), urlSession: server.urlSession)
        Triggerbee.shared.enable() // reset across tests — the singleton's flag survives process-wide
    }

    override func tearDown() async throws {
        Triggerbee.shared.enable()
        await server.stop()
        server = nil
        try await super.tearDown()
    }

    func testDisableMakesAsyncCallsNoOpAndPreventsNetworkRequests() async throws {
        // Arrange
        Triggerbee.shared.disable()

        // Act — none of these should hit the server
        _ = await Triggerbee.shared.start()
        let widgets = try await Triggerbee.shared.pageload(page: "/home", title: "Home")
        try await Triggerbee.shared.logGoal(name: "signup")
        try await Triggerbee.shared.logPurchase(revenue: "199.00")
        try await Triggerbee.shared.pageview(page: "/profile", title: "Profile")
        try await Triggerbee.shared.identify("user@example.com")
        await Triggerbee.shared.setLandingPageQueryParams(["utm_source=test"])

        // Assert
        XCTAssertTrue(widgets.isEmpty)
        XCTAssertEqual(server.requestCount, 0)
        XCTAssertTrue(Triggerbee.shared.isDisabled)
    }

    func testEnableResumesNetworkRequests() async throws {
        // Arrange
        Triggerbee.shared.disable()
        Triggerbee.shared.enable()
        server.enqueue(status: 200, body: """
        {"widgets":[]}
        """)

        // Act
        _ = await Triggerbee.shared.start()
        _ = try await Triggerbee.shared.pageload(page: "/home", title: "Home")

        // Assert
        XCTAssertGreaterThanOrEqual(server.requestCount, 1)
        XCTAssertFalse(Triggerbee.shared.isDisabled)
    }

    func testWidgetUrlReturnsEmptyStringWhenDisabled() {
        // Arrange
        Triggerbee.shared.disable()

        // Act
        let url = Triggerbee.shared.widgetUrl(widgetId: 99)

        // Assert
        XCTAssertEqual(url, "")
    }
}
