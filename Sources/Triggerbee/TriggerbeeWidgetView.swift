#if canImport(WebKit) && canImport(SwiftUI) && (os(iOS) || os(macOS) || os(tvOS))
import Foundation
import SwiftUI
import WebKit

private let initialBoundsTimeoutMs: Int = 3000

/// Renders a Triggerbee widget in a `WKWebView` inside SwiftUI. The widget engine inside the
/// WebView reports its rendered bounds (width, height, position, layout) via the JS bridge;
/// this view sizes and positions the WebView accordingly so non-fullscreen layouts (Callout,
/// Panel, …) only cover their own area and the rest of the host UI stays interactive.
///
/// The WebView starts invisible and fades in once the first bounds are reported, preventing
/// a fullscreen flash before a small callout settles into its corner. If the widget engine
/// fails to report bounds within 3 seconds the SDK closes the widget (via `onClosed(nil)`)
/// and logs a warning — chosen over a fullscreen fallback because a broken-but-invisible
/// fullscreen WebView would trap the host app (no way to scroll or tap through it).
///
/// - Parameters:
///   - widgetId: The widget id, typically the `id` from a ``WidgetCheckResponse``.
///   - onClosed: Invoked when the visitor closes the widget. The SDK has already recorded
///     the dismissal via ``Triggerbee/closeWidget(widgetId:reason:)`` — this callback exists
///     so the host can update its own UI state (e.g. hide the panel).
///   - onNavigate: Invoked when the visitor taps a button in the widget that has a URL.
///     The host decides what to do (in-app routing, open in browser, etc.). Defaults to
///     opening the URL via `UIApplication.shared.open(...)`.
public struct TriggerbeeWidgetView: View {
    private let widgetId: Int
    private let onClosed: (CloseReason?) -> Void
    private let onNavigate: (String) -> Void

    @State private var bounds: Bounds?
    @State private var loadFailed: Bool = false

    public init(
        widgetId: Int,
        onClosed: @escaping (CloseReason?) -> Void = { _ in },
        onNavigate: ((String) -> Void)? = nil
    ) {
        self.widgetId = widgetId
        self.onClosed = onClosed
        // `defaultOnNavigate` is internal, and a default argument value on a public initializer
        // may only reference public symbols — so the default is resolved here in the body
        // rather than in the signature. Keeps the fallback out of the public API surface.
        self.onNavigate = onNavigate ?? { TriggerbeeWidgetView.defaultOnNavigate(url: $0) }
    }

    public var body: some View {
        let alignment = bounds?.position.swiftUIAlignment ?? .center
        ZStack(alignment: alignment) {
            // Transparent root that fills the available space so the alignment can position
            // the WebView within it (matches the Android Compose contentAlignment pattern).
            Color.clear

            if loadFailed {
                EmptyView()
            } else {
                webView
                    .opacity(bounds == nil ? 0 : 1)
                    .animation(.default, value: bounds == nil)
            }
        }
        .task(id: widgetId) {
            // Timeout safeguard: if the widget engine never reports bounds (broken script,
            // blocked network), close the widget via the same path as an outright load
            // failure. A fullscreen fallback risks trapping the host app behind a
            // possibly-invisible WebView with no way to dismiss it.
            try? await Task.sleep(nanoseconds: UInt64(initialBoundsTimeoutMs) * 1_000_000)
            if bounds == nil && !loadFailed {
                Triggerbee.shared.logger().warn(
                    "setBounds not received within \(initialBoundsTimeoutMs)ms; closing WebView"
                )
                loadFailed = true
                onClosed(nil)
            }
        }
    }

    /// The WebView, sized from the reported bounds.
    ///
    /// Deliberately **one** `TriggerbeeWebView` with a computed frame rather than one per layout
    /// case. Separate branches of an `if` are separate view identities in SwiftUI, so switching
    /// branch when `bounds` arrives tore down the WebView and built a new one — reloading the
    /// widget from scratch, running the engine twice and re-fetching the ~430 KB script bundle.
    /// Android has the same structure for the same reason: one `AndroidView`, a computed
    /// `webViewModifier`.
    private var webView: some View {
        let layoutInfo = bounds ?? Bounds(width: 0, height: 0, position: .unknown, layout: .unknown)
        let sizeToScreen = layoutInfo.fillScreen || bounds == nil

        // Exactly one of the three cases supplies each dimension; the other values stay nil so
        // both modifiers are always applied and the view type — and so the identity — is stable.
        let fixedWidth: CGFloat? = (sizeToScreen || layoutInfo.fillWidth) ? nil : CGFloat(layoutInfo.width)
        let fixedHeight: CGFloat? = sizeToScreen ? nil : CGFloat(layoutInfo.height)
        let maxWidth: CGFloat? = (sizeToScreen || layoutInfo.fillWidth) ? .infinity : nil
        let maxHeight: CGFloat? = sizeToScreen ? .infinity : nil

        return TriggerbeeWebView(
            widgetId: widgetId,
            onBoundsChanged: { bounds = $0 },
            onLoadFailed: {
                loadFailed = true
                onClosed(nil)
            },
            onUpdate: { reason in
                let parsed = Self.parseCloseReason(reason)
                Triggerbee.shared.closeWidget(widgetId: widgetId, reason: parsed)
                if Self.isClosingReason(reason) {
                    onClosed(parsed)
                }
            },
            onNavigate: onNavigate
        )
        .frame(width: fixedWidth, height: fixedHeight)
        .frame(maxWidth: maxWidth, maxHeight: maxHeight)
    }

    private static func parseCloseReason(_ raw: String?) -> CloseReason? {
        guard let raw else { return nil }
        return CloseReason(rawValue: raw)
    }

    /// `true` only for reasons that mean "the widget really closed", as opposed to "a tracking
    /// event happened that the backend wants recorded". A conversion (form submitted) leaves
    /// the widget alive — the engine may transition to a success state. A click-through fires
    /// for *every* button click; if the click also closes the widget, an explicit `Closed`
    /// event with `Dismissal` arrives afterwards and triggers the actual tear-down here.
    private static func isClosingReason(_ raw: String?) -> Bool {
        return raw == "Dismissal"
    }

    /// Default `onNavigate`: opens the URL via `UIApplication.shared.open(...)` on iOS / tvOS
    /// or `NSWorkspace.shared.open(...)` on macOS. Suitable when widget buttons link to
    /// external pages. Hosts that route in-app should pass their own closure instead.
    static func defaultOnNavigate(url: String) {
        guard let parsed = URL(string: url) else {
            Triggerbee.shared.logger().warn("defaultOnNavigate: invalid URL \(url)")
            return
        }
        #if os(iOS) || os(tvOS)
        Task { @MainActor in
            if UIApplication.shared.canOpenURL(parsed) {
                UIApplication.shared.open(parsed)
            } else {
                Triggerbee.shared.logger().warn("defaultOnNavigate: cannot open \(url)")
            }
        }
        #elseif os(macOS)
        NSWorkspace.shared.open(parsed)
        #endif
    }
}

// MARK: - UIViewRepresentable wrapper

#if os(iOS) || os(tvOS)
import UIKit
private typealias PlatformViewRepresentable = UIViewRepresentable
#elseif os(macOS)
import AppKit
private typealias PlatformViewRepresentable = NSViewRepresentable
#endif

private struct TriggerbeeWebView: PlatformViewRepresentable {
    let widgetId: Int
    let onBoundsChanged: (Bounds) -> Void
    let onLoadFailed: () -> Void
    let onUpdate: (String?) -> Void
    let onNavigate: (String) -> Void

    func makeCoordinator() -> TriggerbeeWebViewCoordinator {
        return TriggerbeeWebViewCoordinator(
            onBoundsChanged: onBoundsChanged,
            onLoadFailed: onLoadFailed,
            onUpdate: onUpdate,
            onNavigate: onNavigate
        )
    }

    #if os(iOS) || os(tvOS)
    func makeUIView(context: Context) -> WKWebView {
        return buildWebView(coordinator: context.coordinator)
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // No-op: the WebView loads once on creation; further updates are driven by the
        // engine's JS bridge messages.
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: TriggerbeeWebViewCoordinator) {
        coordinator.tearDown(webView: uiView)
    }
    #elseif os(macOS)
    func makeNSView(context: Context) -> WKWebView {
        return buildWebView(coordinator: context.coordinator)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // No-op.
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: TriggerbeeWebViewCoordinator) {
        coordinator.tearDown(webView: nsView)
    }
    #endif

    private func buildWebView(coordinator: TriggerbeeWebViewCoordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        // Inject the global error handlers + reload suppressor before the page evaluates.
        // Matches the Android onPageStarted JS injection so the two SDKs surface identical
        // diagnostics into their respective console pipelines.
        let initScript = WKUserScript(
            source: """
            (function() {
                try { location.reload = function() { console.log('[TB] reload suppressed'); }; } catch(e) {}
                window.onerror = function(msg, src, line, col, err) {
                    console.error('[onerror] ' + msg + ' @ ' + src + ':' + line);
                    return false;
                };
                window.addEventListener('unhandledrejection', function(e) {
                    console.error('[unhandledrejection] ' + e.reason);
                });
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(initScript)

        // Bridge name "triggerbee" — matches native-app-service.ts's iOS dispatch target. The
        // single handler receives every JS call with a `method` field that selects which native
        // action to run. `WKScriptMessageHandlerWithReply` (iOS 14+) lets `hasLoggedOpen`
        // return a value synchronously to the JS caller.
        configuration.userContentController.addScriptMessageHandler(
            coordinator,
            contentWorld: .page,
            name: "triggerbee"
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator

        // Transparent background so the widget controls its own appearance; the SDK's job is
        // sizing + positioning, not rendering a backdrop.
        #if os(iOS) || os(tvOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #elseif os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #endif

        let urlString = Triggerbee.shared.widgetUrl(widgetId: widgetId)
        if let url = URL(string: urlString) {
            Triggerbee.shared.logger().debug("WebView.loadUrl: \(urlString)")
            webView.load(URLRequest(url: url))
        } else {
            coordinator.onLoadFailed()
        }
        return webView
    }
}

// MARK: - Coordinator (delegates + JS bridge)

private final class TriggerbeeWebViewCoordinator: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKUIDelegate {
    private let onBoundsChanged: (Bounds) -> Void
    private let onLoadFailedCallback: () -> Void
    private let onUpdate: (String?) -> Void
    private let onNavigate: (String) -> Void

    init(
        onBoundsChanged: @escaping (Bounds) -> Void,
        onLoadFailed: @escaping () -> Void,
        onUpdate: @escaping (String?) -> Void,
        onNavigate: @escaping (String) -> Void
    ) {
        self.onBoundsChanged = onBoundsChanged
        self.onLoadFailedCallback = onLoadFailed
        self.onUpdate = onUpdate
        self.onNavigate = onNavigate
    }

    fileprivate func onLoadFailed() {
        onLoadFailedCallback()
    }

    fileprivate func tearDown(webView: WKWebView) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "triggerbee", contentWorld: .page)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
    }

    // MARK: - WKScriptMessageHandlerWithReply

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let payload = message.body as? [String: Any],
              let method = payload["method"] as? String else {
            replyHandler(nil, "invalid bridge payload")
            return
        }
        // The widget engine posts a **flat** payload — native-app-service.ts does
        // `postToIos({method:"setBounds", width, height, position, layout})` — not a
        // `{method, args}` envelope. Reading `payload["args"]` therefore found nil for every
        // real widget, so setBounds was dropped and every widget hit the 3s bounds timeout and
        // closed itself. Prefer a nested `args` dictionary if one is ever present, and fall
        // back to the payload itself, which is the shape production actually sends.
        let args: [String: Any] = (payload["args"] as? [String: Any]) ?? payload

        switch method {
        case "update":
            let reason = args["reason"] as? String
            DispatchQueue.main.async { [weak self] in self?.onUpdate(reason) }
            replyHandler(nil, nil)

        case "setBounds":
            let width = (args["width"] as? NSNumber)?.intValue ?? 0
            let height = (args["height"] as? NSNumber)?.intValue ?? 0
            let position = args["position"] as? String
            let layout = args["layout"] as? String
            let parsed = Bounds(
                width: width,
                height: height,
                position: WidgetPosition.from(position),
                layout: WidgetLayout.from(layout)
            )
            Triggerbee.shared.logger().debug(
                "setBounds: \(width)x\(height) position=\(position ?? "(none)") layout=\(layout ?? "(none)")"
            )
            DispatchQueue.main.async { [weak self] in self?.onBoundsChanged(parsed) }
            replyHandler(nil, nil)

        case "failed":
            let reason = args["reason"] as? String
            Triggerbee.shared.logger().warn("Widget engine reported failure: \(reason ?? "(no reason)")")
            DispatchQueue.main.async { [weak self] in self?.onLoadFailedCallback() }
            replyHandler(nil, nil)

        case "navigate":
            let url = args["url"] as? String
            guard let url, !url.isEmpty else {
                replyHandler(nil, nil)
                return
            }
            Triggerbee.shared.logger().debug("navigate: url=\(url)")
            DispatchQueue.main.async { [weak self] in self?.onNavigate(url) }
            replyHandler(nil, nil)

        case "hasLoggedOpen":
            // The engine tracks open-logging internally via nativeAppBridgeService.logOpen and
            // never posts this today; kept for older cached engine builds.
            let id = (args["id"] as? NSNumber)?.intValue ?? -1
            // Synchronous-feeling return via the reply handler. The JS side awaits postMessage.
            replyHandler(Triggerbee.shared.hasLoggedOpen(id), nil)

        case "markOpenLogged":
            let id = (args["id"] as? NSNumber)?.intValue ?? -1
            Triggerbee.shared.markOpenLogged(id)
            replyHandler(nil, nil)

        case "setHeight":
            // Legacy bridge call from the previous SDK version — kept so an older
            // `mytracker.js` cached client-side doesn't crash the bridge. Treated as a no-op.
            replyHandler(nil, nil)

        default:
            Triggerbee.shared.logger().warn("Unknown bridge method: \(method)")
            replyHandler(nil, "unknown method")
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Triggerbee.shared.logger().error("Navigation error: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in self?.onLoadFailedCallback() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Triggerbee.shared.logger().error("Provisional navigation error: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in self?.onLoadFailedCallback() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse,
           navigationResponse.isForMainFrame,
           !(200..<300).contains(http.statusCode) {
            Triggerbee.shared.logger().error(
                "Main-frame HTTP \(http.statusCode) for \(http.url?.absoluteString ?? "(no url)")"
            )
            DispatchQueue.main.async { [weak self] in self?.onLoadFailedCallback() }
            return .cancel
        }
        return .allow
    }

    // MARK: - WKUIDelegate (console.log mirroring isn't part of the public WK API; we forward via the init script only)

    #if os(iOS) || os(tvOS)
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Block window.open / target=_blank — open externally instead.
        if let url = navigationAction.request.url {
            DispatchQueue.main.async { [weak self] in self?.onNavigate(url.absoluteString) }
        }
        return nil
    }
    #endif
}

// MARK: - Bounds + layout helpers (mirror Android internals)

struct Bounds: Equatable {
    let width: Int
    let height: Int
    let position: WidgetPosition
    let layout: WidgetLayout

    var fillScreen: Bool {
        return Self.fillScreenLayouts.contains(layout) || Self.fillScreenPositions.contains(position)
    }

    var fillWidth: Bool {
        return !fillScreen && layout == .panel
    }

    private static let fillScreenLayouts: Set<WidgetLayout> = [.fullscreen, .popup, .unknown]
    // Positions that have no meaningful sub-screen anchor — treat as fullscreen.
    private static let fillScreenPositions: Set<WidgetPosition> = [.center, .embedded, .fullscreen, .productTour, .unknown]
}

private extension WidgetPosition {
    var swiftUIAlignment: Alignment {
        switch self {
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .leading
        case .right: return .trailing
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        case .center, .embedded, .fullscreen, .productTour, .unknown:
            return .center
        }
    }
}

#endif
