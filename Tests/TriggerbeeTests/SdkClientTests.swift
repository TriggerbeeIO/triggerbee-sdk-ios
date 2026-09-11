import XCTest
import Foundation
@testable import Triggerbee

final class SdkClientTests: XCTestCase {

    private var sessionStore: InMemorySessionStore!
    private var mockServer: MockHTTPServer!
    private var client: SdkClient!

    override func setUp() async throws {
        try await super.setUp()
        sessionStore = InMemorySessionStore()
        mockServer = try MockHTTPServer()
        let config = TriggerbeeConfig(siteId: 12345, baseUrl: mockServer.baseUrl)
        let deviceInfo = DeviceInfoCollector.collect()
        client = SdkClient(
            config: config,
            applicationId: "com.example.test",
            sessionStore: sessionStore,
            deviceInfo: deviceInfo,
            urlSession: mockServer.urlSession
        )
    }

    override func tearDown() async throws {
        await mockServer.stop()
        client = nil
        sessionStore = nil
        mockServer = nil
        try await super.tearDown()
    }

    // MARK: - start

    func testStartMintsAndPersistsUidOnFirstCall() async {
        // Arrange
        let expectedUid: Int64 = 42

        // Act
        let uid = await client.start(generate: { expectedUid })

        // Assert
        XCTAssertEqual(uid, expectedUid)
        let persisted = await sessionStore.getUid()
        XCTAssertEqual(persisted, expectedUid)
    }

    func testStartReturnsPersistedUidOnSubsequentCalls() async {
        // Arrange
        await sessionStore.setUid(99)

        // Act
        let uid = await client.start(generate: { fatalError("generate should not be called when uid persisted") })

        // Assert
        XCTAssertEqual(uid, 99)
    }

    // MARK: - pageload

    func testPageloadSendsSiteIdHeaderAndParsesResponse() async throws {
        // Arrange
        _ = await client.start(generate: { 7 })
        mockServer.enqueue(status: 200, body: """
        {"widgets":[{"id":11,"result":true,"openDelay":0},{"id":22,"result":false,"openDelay":5}]}
        """)

        // Act
        let results = try await client.pageload(page: "/home", title: "Home", secondsOnPage: 0)

        // Assert
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].id, 11)
        XCTAssertTrue(results[0].result)
        XCTAssertEqual(results[1].id, 22)
        XCTAssertEqual(results[1].openDelay, 5)
        let request = mockServer.lastRequest()
        XCTAssertEqual(request?.value(forHTTPHeaderField: "X-Site-Id"), "12345")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "X-Application-Id"), "com.example.test")
    }

    func testPageloadSurfacesHttpErrors() async {
        // Arrange
        _ = await client.start(generate: { 7 })
        mockServer.enqueue(status: 500, body: "boom")

        // Act / Assert
        do {
            _ = try await client.pageload(page: "/home", title: "Home", secondsOnPage: 0)
            XCTFail("Expected TriggerbeeError.httpError")
        } catch let TriggerbeeError.httpError(code, body) {
            XCTAssertEqual(code, 500)
            XCTAssertEqual(body, "boom")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - identify

    func testIdentifyPersistsIdentifierAndPropagatesToSessionContext() async throws {
        // Arrange
        _ = await client.start(generate: { 7 })
        mockServer.enqueue(status: 200, body: "")

        // Act
        try await client.identify(identifier: "user@example.com", properties: ["plan": "pro"])

        // Assert
        let persisted = await sessionStore.getIdentifier()
        XCTAssertEqual(persisted, "user@example.com")
        let ctx = await client.sessionContext
        XCTAssertEqual(ctx.identifier, "user@example.com")
    }

    // MARK: - logGoal

    func testLogGoalPersistsGoalInAudienceState() async throws {
        // Arrange
        _ = await client.start(generate: { 7 })
        mockServer.enqueue(status: 200, body: "")

        // Act
        try await client.logGoal(name: "signup", revenue: nil)

        // Assert
        let audience = await sessionStore.getAudienceState()
        XCTAssertEqual(audience.goals, ["signup"])
    }

    // MARK: - widgetUrl

    func testWidgetUrlContainsAllRequiredParams() async {
        // Arrange
        _ = await client.start(generate: { 7 })

        // Act
        let url = await client.widgetUrl(widgetId: 99, uid: 7)

        // Assert
        XCTAssertTrue(url.contains("/v2/client/widgets/99/html"))
        XCTAssertTrue(url.contains("siteId=12345"))
        XCTAssertTrue(url.contains("uid=7"))
        XCTAssertTrue(url.contains("applicationId="))
        XCTAssertTrue(url.contains("targetDevice=NativeApp"))
    }

    // MARK: - batch

    func testBatchSendsCombinedRequestAndUpdatesIdentifier() async throws {
        // Arrange
        _ = await client.start(generate: { 7 })
        mockServer.enqueue(status: 200, body: "")

        // Act
        try await client.batch(
            pageviews: [BatchPageview(path: "/a", title: "A")],
            goals: [BatchGoal(name: "g1")],
            purchases: [BatchPurchase(revenue: "100.00")],
            identify: BatchIdentify(identifier: "user@example.com")
        )

        // Assert
        let ctx = await client.sessionContext
        XCTAssertEqual(ctx.identifier, "user@example.com")
    }
}
