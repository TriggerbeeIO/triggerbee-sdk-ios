import Foundation

/// Errors surfaced by the Triggerbee SDK. All network-related calls translate underlying
/// `URLError`s, non-2xx HTTP responses, and decoding errors into one of these cases.
public enum TriggerbeeError: Error, LocalizedError {

    /// A method was called before ``Triggerbee/configure(_:)``. Configure the SDK first
    /// (typically in your app's `init` or `AppDelegate.application(_:didFinishLaunchingWithOptions:)`).
    case notInitialized

    /// A tracking method was called before ``Triggerbee/start()`` had minted the visitor id.
    /// Call `await Triggerbee.shared.start()` once during launch before logging events.
    ///
    /// The Android SDK raises `IllegalArgumentException` from `require(uid != 0L)` here. Swift
    /// has no unchecked exceptions and these methods already throw, so the same programmer
    /// error surfaces as a typed case instead of trapping the host process.
    case notStarted

    /// The backend returned a non-2xx status code. `body` is the response body for
    /// diagnostics — may be empty.
    case httpError(code: Int, body: String)

    /// Connection failed, request timed out, or the device is offline.
    case networkError(Error)

    /// The response was 2xx but the body couldn't be parsed into the expected shape — usually
    /// a wire-protocol bug between SDK and backend.
    case serializationError(Error)

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Triggerbee.configure(...) must be called before any other SDK method"
        case .notStarted:
            return "Triggerbee.start() must be called before logging events or building widget URLs"
        case .httpError(let code, let body):
            return "HTTP \(code) — \(body)"
        case .networkError(let cause):
            return "Network error: \(cause.localizedDescription)"
        case .serializationError(let cause):
            return "Failed to parse response: \(cause.localizedDescription)"
        }
    }
}
