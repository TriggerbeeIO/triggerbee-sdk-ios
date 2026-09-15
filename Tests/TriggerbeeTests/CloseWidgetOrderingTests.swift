import XCTest
@testable import Triggerbee

/// `closeWidget(widgetId:reason:)` is synchronous by design, so its persist runs off an
/// unstructured `Task`. `SdkClient` is an actor, and actors make no ordering promise between
/// separately enqueued calls, so a pageload issued in the same turn used to build its request
/// before the entry landed — dropping the repetition rule for the widget the visitor had just
/// dismissed, which brought that widget straight back.
final class CloseWidgetOrderingTests: XCTestCase {

    private var server: MockHTTPServer!

    override func setUp() async throws {
        try await super.setUp()
        server = try MockHTTPServer()
        Triggerbee.shared.enable()
    }

    override func tearDown() async throws {
        Triggerbee.shared.enable()
        await server.stop()
        server = nil
        try await super.tearDown()
    }

    private func configure() {
        let config = TriggerbeeConfig(siteId: 12345, baseUrl: server.baseUrl)
        Triggerbee.shared.configureForTesting(
            config,
            sessionStore: InMemorySessionStore(),
            urlSession: server.urlSession
        )
    }

    /// Widget ids in the `closedWidgets` array of the most recent request body, in wire order.
    private func closedWidgetIdsInLastRequest() throws -> [Int] {
        let body = try XCTUnwrap(server.lastRequest()?.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let closed = try XCTUnwrap(json["closedWidgets"] as? [[String: Any]])
        return closed.compactMap { $0["widgetId"] as? Int }
    }

    func testCloseWidgetReachesAPageloadIssuedImmediatelyAfter() async throws {
        // Arrange
        configure()
        await Triggerbee.shared.start()
        server.enqueue(status: 200, body: #"{"widgets":[]}"#)

        // Act — deliberately no gap between the two calls. This is what the visitor produces
        // when they dismiss a widget and the app navigates on the same turn.
        Triggerbee.shared.closeWidget(widgetId: 77, reason: .dismissal)
        _ = try await Triggerbee.shared.pageload(page: "/next", title: "Next")

        // Assert
        XCTAssertEqual(try closedWidgetIdsInLastRequest(), [77])
    }

    func testCloseWidgetReachesARecheckIssuedImmediatelyAfter() async throws {
        // Arrange
        configure()
        await Triggerbee.shared.start()
        server.enqueue(status: 200, body: #"{"widgets":[]}"#)

        // Act
        Triggerbee.shared.closeWidget(widgetId: 88, reason: .conversion)
        _ = try await Triggerbee.shared.recheck(page: "/same", secondsOnPage: 3)

        // Assert
        XCTAssertEqual(try closedWidgetIdsInLastRequest(), [88])
    }

    func testConsecutiveClosesAllReachTheNextPageloadInCallOrder() async throws {
        // Arrange
        configure()
        await Triggerbee.shared.start()
        server.enqueue(status: 200, body: #"{"widgets":[]}"#)

        // Act — closes are chained, so they must also not race each other.
        Triggerbee.shared.closeWidget(widgetId: 1, reason: .dismissal)
        Triggerbee.shared.closeWidget(widgetId: 2, reason: .dismissal)
        Triggerbee.shared.closeWidget(widgetId: 3, reason: .clickthrough)
        _ = try await Triggerbee.shared.pageload(page: "/next", title: "Next")

        // Assert
        XCTAssertEqual(try closedWidgetIdsInLastRequest(), [1, 2, 3])
    }

    func testReclosingTheSameWidgetDoesNotDuplicateTheEntry() async throws {
        // Arrange
        configure()
        await Triggerbee.shared.start()
        server.enqueue(status: 200, body: #"{"widgets":[]}"#)

        // Act
        Triggerbee.shared.closeWidget(widgetId: 42, reason: .dismissal)
        Triggerbee.shared.closeWidget(widgetId: 42, reason: .conversion)
        _ = try await Triggerbee.shared.pageload(page: "/next", title: "Next")

        // Assert — deduped by widgetId, latest reason wins.
        XCTAssertEqual(try closedWidgetIdsInLastRequest(), [42])
    }

    func testCloseWidgetIsANoOpWhileDisabled() async throws {
        // Arrange
        configure()
        await Triggerbee.shared.start()
        Triggerbee.shared.disable()
        Triggerbee.shared.closeWidget(widgetId: 99, reason: .dismissal)
        Triggerbee.shared.enable()
        server.enqueue(status: 200, body: #"{"widgets":[]}"#)

        // Act
        _ = try await Triggerbee.shared.pageload(page: "/next", title: "Next")

        // Assert — nothing was recorded while disabled, and awaiting the barrier still works.
        XCTAssertEqual(try closedWidgetIdsInLastRequest(), [])
    }
}
