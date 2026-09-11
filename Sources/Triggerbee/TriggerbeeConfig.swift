import Foundation

/// Configuration passed once to ``Triggerbee/configure(_:)``.
///
/// - Parameters:
///   - siteId: The Triggerbee site id (visible in the dashboard URL).
///   - baseUrl: Root URL of the Triggerbee Public API. Defaults to the production
///     endpoint (`https://api.triggerbee.com`). Override to point at a non-production
///     environment. Any trailing slash is stripped.
///   - applicationId: Override for the auto-detected application id. Left nil in normal
///     usage; the SDK reads `Bundle.main.bundleIdentifier` during init. Set only when the
///     app needs to identify as a different bundle (white-label rebuilds).
///   - connectTimeout: HTTP request timeout (applied to URLSessionConfiguration.timeoutIntervalForRequest).
///   - readTimeout: Resource-fetch timeout (applied to URLSessionConfiguration.timeoutIntervalForResource).
///   - logger: Where SDK diagnostic logs go. Defaults to ``NoOpLogger`` (silent). Wire in
///     ``OSLogger`` when you want SDK + WebView events surfaced in Console.app / os_log.
///   - userAgent: Optional User-Agent override. When nil, URLSession's default is used.
public struct TriggerbeeConfig: Sendable {
    public let siteId: Int64
    public let baseUrl: String
    public let applicationId: String?
    public let connectTimeout: TimeInterval
    public let readTimeout: TimeInterval
    public let logger: TriggerbeeLogger
    public let userAgent: String?

    /// Production Public API URL — applied when `baseUrl` isn't specified.
    public static let defaultBaseUrl: String = "https://api.triggerbee.com"

    public init(
        siteId: Int64,
        baseUrl: String = TriggerbeeConfig.defaultBaseUrl,
        applicationId: String? = nil,
        connectTimeout: TimeInterval = 10,
        readTimeout: TimeInterval = 10,
        logger: TriggerbeeLogger = NoOpLogger(),
        userAgent: String? = nil
    ) {
        // Android validates with require(), which throws a catchable IllegalArgumentException.
        // The Swift equivalent used precondition, which traps and kills the host process in a
        // release build — unacceptable in an embedded SDK. So: normalise what can be normalised
        // here, and let Triggerbee.configure(_:) reject the rest with a logged error, leaving
        // the SDK unconfigured so subsequent calls throw TriggerbeeError.notInitialized.
        self.siteId = siteId
        // A trailing slash would produce "//v2/client/..." in every request path.
        var normalisedBaseUrl = baseUrl
        while normalisedBaseUrl.hasSuffix("/") { normalisedBaseUrl.removeLast() }
        self.baseUrl = normalisedBaseUrl
        self.applicationId = applicationId
        self.connectTimeout = connectTimeout
        self.readTimeout = readTimeout
        self.logger = logger
        self.userAgent = userAgent
    }
}
