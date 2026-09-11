import Foundation

/// In-process HTTP mock for SDK tests. Uses `URLProtocol` to intercept requests made through
/// the test-injected `URLSession` and replay canned responses. Drop-in equivalent of the
/// MockWebServer the Android tests use — same `enqueue(status:body:)` + `lastRequest()`
/// + `requestCount` surface.
///
/// Thread-safety: response queues and captured requests are **per instance**, not shared
/// statics. `URLProtocol` subclasses are instantiated by URLSession, so the stub can't be handed
/// a reference directly; instead each server claims a unique hostname and registers itself, and
/// the stub resolves the right instance from the request's host. Two servers can therefore be
/// live at once without stealing each other's responses, which is what enabling parallel test
/// execution would otherwise do.
final class MockHTTPServer: @unchecked Sendable {
    fileprivate struct Response {
        let status: Int
        let body: Data
        let headers: [String: String]
    }

    // MARK: - Instance registry, keyed by the server's unique host

    private static let registryLock = NSLock()
    private static var registry: [String: MockHTTPServer] = [:]

    fileprivate static func server(forHost host: String?) -> MockHTTPServer? {
        guard let host else { return nil }
        return registryLock.withLock { registry[host] }
    }

    // MARK: - Per-instance state

    private let lock = NSLock()
    private var responses: [Response] = []
    private var requests: [URLRequest] = []
    private let defaultResponse = Response(status: 204, body: Data(), headers: [:])

    /// Unique per instance so concurrent servers don't intercept each other's traffic.
    private let host: String

    /// Base URL the SDK should target.
    let baseUrl: String

    /// URLSession configured to use the stub for all requests. Pass this to
    /// `SdkClient.init(..., urlSession:)` or `Triggerbee.configureForTesting(..., urlSession:)`.
    let urlSession: URLSession

    init() throws {
        self.host = "mock-\(UUID().uuidString.lowercased()).test"
        self.baseUrl = "http://\(host)"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self] + (config.protocolClasses ?? [])
        self.urlSession = URLSession(configuration: config)
        Self.registryLock.withLock { Self.registry[host] = self }
    }

    func stop() async {
        Self.registryLock.withLock { Self.registry.removeValue(forKey: host) }
        lock.withLock {
            responses.removeAll()
            requests.removeAll()
        }
        urlSession.invalidateAndCancel()
    }

    /// Enqueue a response for the next request. FIFO: the first enqueued response is returned
    /// for the first request, second for the second, etc. If the queue runs out, the stub
    /// returns 204 No Content.
    func enqueue(status: Int, body: String, headers: [String: String] = [:]) {
        lock.withLock {
            responses.append(Response(status: status, body: body.data(using: .utf8) ?? Data(), headers: headers))
        }
    }

    func lastRequest() -> URLRequest? {
        return lock.withLock { requests.last }
    }

    var requestCount: Int {
        return lock.withLock { requests.count }
    }

    fileprivate func consumeNextResponse() -> Response {
        return lock.withLock {
            if responses.isEmpty {
                return defaultResponse
            }
            return responses.removeFirst()
        }
    }

    fileprivate func recordRequest(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }
}

private final class URLProtocolStub: URLProtocol {
    // Only claim requests addressed to a live MockHTTPServer, so a stray request in a parallel
    // test isn't answered by the wrong server (or by a server that has already stopped).
    override class func canInit(with request: URLRequest) -> Bool {
        return MockHTTPServer.server(forHost: request.url?.host) != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { return request }

    override func startLoading() {
        guard let url = request.url, let server = MockHTTPServer.server(forHost: url.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        // URLRequest.httpBody is nil when set via httpBodyStream (which URLSession does internally).
        // Re-materialize it so test assertions can read the body.
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            captured.httpBody = readStream(stream)
        }
        server.recordRequest(captured)

        let response = server.consumeNextResponse()
        var headers = response.headers
        if headers["Content-Type"] == nil {
            headers["Content-Type"] = "application/json"
        }
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func readStream(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
