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

    // MARK: - Query encoding

    func testApplicationIdWithQueryDelimitersIsPercentEncoded() async {
        // Arrange — CharacterSet.urlQueryAllowed permits & and =, so encoding with it would
        // leave this value able to open new query parameters. Only reachable through the
        // explicit TriggerbeeConfig(applicationId:) override; a bundle id cannot contain these.
        let config = TriggerbeeConfig(siteId: 12345, baseUrl: mockServer.baseUrl)
        let injected = SdkClient(
            config: config,
            applicationId: "com.acme&siteId=999",
            sessionStore: InMemorySessionStore(),
            deviceInfo: DeviceInfoCollector.collect(),
            urlSession: mockServer.urlSession
        )

        // Act
        let url = injected.widgetUrl(widgetId: 5, uid: 7)

        // Assert — the delimiters are escaped, so siteId still appears exactly once.
        XCTAssertTrue(url.contains("applicationId=com.acme%26siteId%3D999"), url)
        XCTAssertEqual(url.components(separatedBy: "siteId=").count - 1, 1, url)
    }

    func testOrdinaryBundleIdentifierIsLeftIntactInWidgetUrl() {
        // Arrange — the encoding must not mangle a normal bundle id.

        // Act
        let url = client.widgetUrl(widgetId: 5, uid: 7)

        // Assert
        XCTAssertTrue(url.contains("applicationId=com.example.test"), url)
    }

    // MARK: - Identifier normalisation

    func testEmptyIdentifierLeavesMemoryAndStoreAgreeing() async throws {
        // Arrange — the store reads "" back as nil, so mirroring the raw value into the
        // in-memory context would make the two disagree after a relaunch.
        _ = await client.start(generate: { 7 })
        mockServer.enqueue(status: 200, body: "{}")

        // Act
        try await client.identify(identifier: "", properties: [:])

        // Assert
        let context = await client.sessionContext
        XCTAssertNil(context.identifier)
        let persisted = await sessionStore.getIdentifier()
        XCTAssertNil(persisted)
    }

    func testNonEmptyIdentifierIsMirroredIntoSessionContext() async throws {
        // Arrange
        _ = await client.start(generate: { 7 })
        mockServer.enqueue(status: 200, body: "{}")

        // Act
        try await client.identify(identifier: "user@acme.com", properties: [:])

        // Assert
        let context = await client.sessionContext
        XCTAssertEqual(context.identifier, "user@acme.com")
        let persisted = await sessionStore.getIdentifier()
        XCTAssertEqual(persisted, "user@acme.com")
    }
}
