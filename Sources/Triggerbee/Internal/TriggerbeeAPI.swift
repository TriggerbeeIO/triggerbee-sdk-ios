import Foundation

/// URLSession-based client for PublicApiGateway's client-to-server endpoints.
/// All routes live under the `/v2/client/` prefix and are authenticated by the
/// `X-Application-Id` header (matched against the account's `AllowedApplicationIds`).
/// `X-Target-Device: NativeApp` is set on every request — required by V2 widget endpoints.
///
/// Mirrors the surface of Android's Retrofit `TriggerbeeApi` interface — same routes,
/// same request bodies, same headers — so the two SDKs stay wire-compatible.
struct TriggerbeeAPI {
    let baseUrl: String
    let session: URLSession
    let applicationId: String
    let userAgent: String?
    let logger: TriggerbeeLogger

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseUrl: String,
        session: URLSession,
        applicationId: String,
        userAgent: String?,
        logger: TriggerbeeLogger
    ) {
        self.baseUrl = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        self.session = session
        self.applicationId = applicationId
        self.userAgent = userAgent
        self.logger = logger

        // Matches kotlinx.serialization's `explicitNulls = false` on the Android side: nil
        // optionals are omitted from the request body rather than sent as `null`. No encoder
        // configuration is needed for that — Swift's synthesized `Encodable` conformance already
        // calls `encodeIfPresent` for Optional properties, and every DTO here uses plain
        // Optional<T>.
        let encoder = JSONEncoder()
        self.encoder = encoder

        let decoder = JSONDecoder()
        self.decoder = decoder
    }

    func pageload(siteId: Int64, request: PageloadRequest) async throws -> CheckWidgetsResponse {
        return try await post("/v2/client/widgets/pageload", siteId: siteId, body: request)
    }

    func check(siteId: Int64, request: CheckRequest) async throws -> CheckWidgetsResponse {
        return try await post("/v2/client/widgets/audiences/check", siteId: siteId, body: request)
    }

    func identify(siteId: Int64, uid: Int64, request: IdentifyRequest) async throws {
        let _: EmptyResponse = try await post("/v2/client/events/\(uid)/identify", siteId: siteId, body: request)
    }

    func goal(siteId: Int64, uid: Int64, request: GoalRequest) async throws {
        let _: EmptyResponse = try await post("/v2/client/events/\(uid)/goal", siteId: siteId, body: request)
    }

    func pageview(siteId: Int64, uid: Int64, request: PageviewRequest) async throws {
        let _: EmptyResponse = try await post("/v2/client/events/\(uid)/pageview", siteId: siteId, body: request)
    }

    func purchase(siteId: Int64, uid: Int64, request: PurchaseRequest) async throws {
        let _: EmptyResponse = try await post("/v2/client/events/\(uid)/purchase", siteId: siteId, body: request)
    }

    func batch(siteId: Int64, uid: Int64, request: BatchRequest) async throws {
        let _: EmptyResponse = try await post("/v2/client/events/\(uid)/batch", siteId: siteId, body: request)
    }

    // MARK: - HTTP plumbing

    private func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        siteId: Int64,
        body: Body
    ) async throws -> Response {
        guard let url = URL(string: baseUrl + path) else {
            throw TriggerbeeError.networkError(URLError(.badURL))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(applicationId, forHTTPHeaderField: "X-Application-Id")
        req.setValue(String(siteId), forHTTPHeaderField: "X-Site-Id")
        // Required on V2 widget endpoints; harmless on event endpoints. Native SDK always targets NativeApp.
        req.setValue("NativeApp", forHTTPHeaderField: "X-Target-Device")
        if let userAgent {
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        do {
            req.httpBody = try encoder.encode(body)
        } catch {
            throw TriggerbeeError.serializationError(error)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw TriggerbeeError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TriggerbeeError.networkError(URLError(.cannotParseResponse))
        }

        if !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw TriggerbeeError.httpError(code: http.statusCode, body: bodyText)
        }

        // Void-typed callers pass EmptyResponse; ignore the body unconditionally for those.
        if Response.self == EmptyResponse.self {
            return EmptyResponse() as! Response
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw TriggerbeeError.serializationError(error)
        }
    }
}

/// Sentinel response type for void-returning endpoints (`identify`, `goal`, `purchase`, etc.).
/// `Decodable` so the generic `post(...)` signature compiles; never actually decoded — the
/// API client short-circuits for this exact type.
struct EmptyResponse: Decodable {}
