import Foundation

// Wire-format DTOs. All Codable so JSONEncoder/JSONDecoder can round-trip them.
// Names use the camelCase the backend expects (matches the Android SDK's kotlinx.serialization shapes).

struct PageloadRequest: Codable {
    let pageview: PageviewDto
    let currentVisit: CurrentVisit
    let closedWidgets: [ClosedWidget]
    let visitorData: VisitorData?
    let device: DeviceInfoDto?
}

struct CheckRequest: Codable {
    let currentVisit: CurrentVisit
    let closedWidgets: [ClosedWidget]
    let visitorData: VisitorData?
    let device: DeviceInfoDto?
}

/// Wire representation of ``DeviceInfo``. Same shape; the indirection exists so the public
/// API model stays in `Models/` (a stable surface) while the wire DTO can evolve
/// independently if the server protocol drifts.
struct DeviceInfoDto: Codable {
    let platform: String
    let type: String
    let osVersion: String
    let osApiLevel: Int
    let sdkVersion: String
    let manufacturer: String
    let model: String
    let appVersion: String?
    let locale: String
    let timeZone: String
    let screenWidth: Int
    let screenHeight: Int
}

struct PageviewDto: Codable {
    let path: String
    let title: String
}

struct CurrentVisit: Codable {
    let uid: Int64
    let page: String
    let secondsOnPage: Int
    let pageviews: Int
    let usersTime: String
    let ipAddress: String?
}

struct ClosedWidget: Codable {
    let widgetId: Int
    let closedTime: Int64
    let reason: String?
    let pageviews: Int
}

struct VisitorData: Codable {
    let identifier: String?
    let goals: [String]
    let landingPageQueryParams: [String]
}

/// Local-only mirror of the visitor's audience-relevant state. Persisted as one JSON blob in
/// UserDefaults so we can do realtime audience matching on the next pageload without waiting
/// for the data to land in the Visitors database. Identifier lives in ``SessionContext``;
/// this only carries fields the server doesn't already echo back to us.
struct VisitorAudienceState: Codable, Equatable {
    var goals: [String] = []
    var landingPageQueryParams: [String] = []
}

struct CheckWidgetsResponse: Codable {
    let widgets: [WidgetCheckDto]

    init(widgets: [WidgetCheckDto] = []) {
        self.widgets = widgets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.widgets = try container.decodeIfPresent([WidgetCheckDto].self, forKey: .widgets) ?? []
    }
}

struct WidgetCheckDto: Codable {
    let id: Int
    let result: Bool
    let openDelay: Int

    init(id: Int, result: Bool, openDelay: Int = 0) {
        self.id = id
        self.result = result
        self.openDelay = openDelay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int.self, forKey: .id)
        self.result = try container.decode(Bool.self, forKey: .result)
        self.openDelay = try container.decodeIfPresent(Int.self, forKey: .openDelay) ?? 0
    }
}

struct IdentifyRequest: Codable {
    let identifier: String
    let properties: [String: String]
    let device: DeviceInfoDto?
}

struct GoalRequest: Codable {
    let name: String
    let revenue: String?
    let device: DeviceInfoDto?
}

struct PurchaseRequest: Codable {
    let revenue: String?
    let couponCode: String?
    let device: DeviceInfoDto?
}

struct PageviewRequest: Codable {
    let path: String
    let title: String
    let device: DeviceInfoDto?
}

// Mirrors PublicApiGateway's EventsBatchRequest. All groups optional; sent as `null` (not `[]`)
// when absent so the backend can short-circuit empty lists. Device lives at the root only —
// nested items intentionally have no device field.
struct BatchRequest: Codable {
    let pageviews: [BatchPageviewDto]?
    let goals: [BatchGoalDto]?
    let purchases: [BatchPurchaseDto]?
    let identify: BatchIdentifyDto?
    let device: DeviceInfoDto?
}

struct BatchPageviewDto: Codable {
    let path: String?
    let title: String?
}

struct BatchPurchaseDto: Codable {
    let revenue: String?
    let couponCode: String?
}

struct BatchGoalDto: Codable {
    let name: String
    let revenue: String?
}

struct BatchIdentifyDto: Codable {
    let identifier: String?
    let properties: [String: String]?
}
