import Foundation

/// Result of a per-page widget check from the backend. The SDK returns an array of these from
/// ``Triggerbee/pageload(page:title:secondsOnPage:)`` and ``Triggerbee/recheck(page:secondsOnPage:)``;
/// callers typically pick the first `result == true` widget to render.
///
/// - Parameters:
///   - id: The widget id; pass to ``Triggerbee/widgetUrl(widgetId:)`` to load the rendered HTML.
///   - result: `true` if the widget should be shown to this visitor right now.
///   - openDelay: Seconds remaining until a time-based trigger fires. Non-zero only when
///     `result` is false because an AfterXSeconds trigger has not yet elapsed; schedule a
///     `recheck` after this delay.
public struct WidgetCheckResponse: Sendable, Equatable {
    public let id: Int
    public let result: Bool
    public let openDelay: Int

    public init(id: Int, result: Bool, openDelay: Int) {
        self.id = id
        self.result = result
        self.openDelay = openDelay
    }
}

/// Reason a widget was closed by the visitor — sent to the backend so it can apply the
/// matching repetition rule (e.g. "don't show again for 7 days").
public enum CloseReason: String, Sendable, CaseIterable {
    case dismissal = "Dismissal"
    case conversion = "Conversion"
    case clickThrough = "ClickThrough"
}

/// Visual mode of a widget state, reported by the widget engine via the JS bridge so the SDK
/// can size and position the WebView appropriately. `unknown` is the safe fallback for any
/// value the SDK doesn't yet recognize — the SDK treats unknown layouts as fullscreen.
public enum WidgetLayout: String, Sendable {
    case fullscreen = "Fullscreen"
    case popup = "Popup"
    case panel = "Panel"
    case callout = "Callout"
    case unknown = "Unknown"

    public static func from(_ value: String?) -> WidgetLayout {
        guard let value else { return .unknown }
        return WidgetLayout(rawValue: value) ?? .unknown
    }
}

/// Anchor point of a widget within its containing viewport, reported by the widget engine.
/// Mirrors `Triggerbee.Widgets.Core.Enums.WidgetPosition` on the backend so wire values pass
/// through unchanged. `center`, `embedded`, `fullscreen`, and `productTour` are treated as
/// fill-screen by the SDK.
public enum WidgetPosition: String, Sendable {
    case center = "Center"
    case top = "Top"
    case bottom = "Bottom"
    case left = "Left"
    case right = "Right"
    case topLeft = "TopLeft"
    case topRight = "TopRight"
    case bottomLeft = "BottomLeft"
    case bottomRight = "BottomRight"
    case embedded = "Embedded"
    case fullscreen = "Fullscreen"
    case productTour = "ProductTour"
    case unknown = "Unknown"

    public static func from(_ value: String?) -> WidgetPosition {
        guard let value else { return .unknown }
        return WidgetPosition(rawValue: value) ?? .unknown
    }
}

/// Snapshot of the device the SDK is running on. Built once at ``Triggerbee/configure(_:)``
/// and sent in every pageload/recheck request so audience filters can match on device
/// attributes.
///
/// All fields are inferred from `UIDevice` / `Locale` / `Bundle` — no permissions, no PII,
/// no device identifiers.
public struct DeviceInfo: Sendable, Equatable {
    /// Always `"ios"` on this platform.
    public let platform: String
    /// Device class: `"mobile"`, `"tablet"`, or `"desktop"`.
    public let type: String
    /// iOS version string, e.g. `"17.3.1"`.
    public let osVersion: String
    /// iOS major version as an integer for parity with Android's API level field, e.g. `17`.
    public let osApiLevel: Int
    /// Triggerbee SDK semver, e.g. `"0.1.0"`.
    public let sdkVersion: String
    /// Device manufacturer — always `"Apple"` on this platform.
    public let manufacturer: String
    /// Device model identifier, e.g. `"iPhone15,3"`.
    public let model: String
    /// Host app's `CFBundleShortVersionString`, or nil if unreadable.
    public let appVersion: String?
    /// BCP-47 language tag, e.g. `"en-US"`.
    public let locale: String
    /// IANA time-zone id, e.g. `"Europe/Stockholm"`.
    public let timeZone: String
    /// Display width in points × scale (physical pixels).
    public let screenWidth: Int
    /// Display height in points × scale (physical pixels).
    public let screenHeight: Int

    public init(
        platform: String,
        type: String,
        osVersion: String,
        osApiLevel: Int,
        sdkVersion: String,
        manufacturer: String,
        model: String,
        appVersion: String?,
        locale: String,
        timeZone: String,
        screenWidth: Int,
        screenHeight: Int
    ) {
        self.platform = platform
        self.type = type
        self.osVersion = osVersion
        self.osApiLevel = osApiLevel
        self.sdkVersion = sdkVersion
        self.manufacturer = manufacturer
        self.model = model
        self.appVersion = appVersion
        self.locale = locale
        self.timeZone = timeZone
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
    }
}

/// Pageview entry in a ``Triggerbee/batch(pageviews:goals:purchases:identify:)`` call.
public struct BatchPageview: Sendable {
    public let path: String
    public let title: String?
    public init(path: String, title: String? = nil) {
        self.path = path
        self.title = title
    }
}

/// Goal entry in a ``Triggerbee/batch(pageviews:goals:purchases:identify:)`` call.
public struct BatchGoal: Sendable {
    public let name: String
    public let revenue: String?
    public init(name: String, revenue: String? = nil) {
        self.name = name
        self.revenue = revenue
    }
}

/// Purchase entry in a ``Triggerbee/batch(pageviews:goals:purchases:identify:)`` call.
/// `revenue` is a string so the caller controls formatting (e.g. `"199.00"`).
public struct BatchPurchase: Sendable {
    public let revenue: String?
    public let couponCode: String?
    public init(revenue: String? = nil, couponCode: String? = nil) {
        self.revenue = revenue
        self.couponCode = couponCode
    }
}

/// Identify entry in a ``Triggerbee/batch(pageviews:goals:purchases:identify:)`` call.
public struct BatchIdentify: Sendable {
    public let identifier: String
    public let properties: [String: String]
    public init(identifier: String, properties: [String: String] = [:]) {
        self.identifier = identifier
        self.properties = properties
    }
}

/// Read-only snapshot of session state observable via ``Triggerbee/sessionContext`` and
/// ``Triggerbee/sessionContextStream``.
///
/// - Parameters:
///   - uid: Visitor id assigned by ``Triggerbee/start()``. `0` before start.
///   - pageviews: How many pageloads have been logged in this process lifetime (in-memory,
///     resets on process death — same semantics as the web SDK's `sessionStorage`).
///   - identifier: Email or other identifier set by ``Triggerbee/identify(_:properties:)``.
public struct SessionContext: Sendable, Equatable {
    public let uid: Int64
    public let pageviews: Int
    public let identifier: String?

    public init(uid: Int64, pageviews: Int, identifier: String?) {
        self.uid = uid
        self.pageviews = pageviews
        self.identifier = identifier
    }
}
