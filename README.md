# Triggerbee SDK for iOS

Native iOS SDK for the Triggerbee platform. Wraps the public REST API, generates and
persists the visitor id locally, and exposes a small async/await surface for pageload
tracking, widget checks, identification, and goal logging.

> **Status:** 0.1.0 — pre-1.0. The public API may change in minor releases until 1.0.

**API reference:** <https://triggerbeeio.github.io/triggerbee-sdk-ios/> — auto-generated from the
DocC comments on every `main` push.

## Integration checklist

A copy-paste checklist for getting Triggerbee live in your app. The next section has the
full example; this is the bird's-eye list.

**Before you start**
- [ ] Get your `siteId` (numeric) from your Triggerbee account manager
- [ ] Add your app's bundle identifier (e.g. `com.acme.shop`) to your account under
      **Account Settings → General → "Also accept traffic from the following native apps"**,
      one per line

**Add the SDK**
- [ ] iOS 15 minimum, Xcode 15+
- [ ] Xcode → File → Add Package Dependencies → paste
      `https://github.com/TriggerbeeIO/triggerbee-sdk-ios.git` → choose your target

**Initialize once** *(in your `App` init or `AppDelegate.application(_:didFinishLaunchingWithOptions:)`)*
- [ ] Configure the singleton, then start the session:

```swift
import Triggerbee

Triggerbee.shared.configure(TriggerbeeConfig(siteId: YOUR_SITE_ID))
Task { await Triggerbee.shared.start() }   // safe to call every launch — only mints the UID first time
```

**Track screens**
- [ ] On each screen view:
      `try await Triggerbee.shared.pageload(page: "/products/42", title: "Product")`
- [ ] Optional:
      `try await Triggerbee.shared.recheck(page: "/products/42", secondsOnPage: 5)`
      after a delay for time-based campaigns

**Identify & convert** *(when applicable)*
- [ ] On login / known visitor:
      `try await Triggerbee.shared.identify("user@acme.com")`
- [ ] On purchase:
      `try await Triggerbee.shared.logPurchase(revenue: "299.00")`
- [ ] Custom goals:
      `try await Triggerbee.shared.logGoal(name: "newsletter_signup")`

**Render widgets** *(when a pageload result has campaigns)*
- [ ] SwiftUI: drop `TriggerbeeWidgetView(widgetId: hit.id)` into your view tree
- [ ] UIKit: load `Triggerbee.shared.widgetUrl(widgetId: hit.id)` into your own `WKWebView`

**Verify**
- [ ] Build + run, perform the steps that should trigger a campaign
- [ ] In the Triggerbee dashboard, confirm the visit + events appear under your `siteId`

## Full quick start

```swift
import Triggerbee
import SwiftUI

@main
struct MyApp: App {
    init() {
        Triggerbee.shared.configure(
            TriggerbeeConfig(siteId: YOUR_SITE_ID)
        )
    }

    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    @State private var widgetIds: [Int] = []

    var body: some View {
        ZStack {
            // ... your app UI ...
            ForEach(widgetIds, id: \.self) { id in
                TriggerbeeWidgetView(widgetId: id, onClosed: { _ in
                    widgetIds.removeAll(where: { $0 == id })
                })
            }
        }
        .task {
            await Triggerbee.shared.start()
            let widgets = (try? await Triggerbee.shared.pageload(page: "/profile", title: "Profile")) ?? []
            widgetIds = widgets.filter { $0.result }.map { $0.id }
        }
    }
}
```

## What's in the box

| Method | Purpose |
|---|---|
| `Triggerbee.shared.configure(_:)` | Configure once (typically in your `App` init). |
| `Triggerbee.shared.start()` | Mint a 64-bit visitor id on first launch; reuse it forever after. Client-side `SystemRandomNumberGenerator`, no network. |
| `Triggerbee.shared.pageload(page:title:secondsOnPage:)` | Log a pageview + get the widgets eligible to show on this page. |
| `Triggerbee.shared.recheck(page:secondsOnPage:)` | Re-evaluate widgets without logging a new pageview (use after waiting out an `openDelay`). |
| `Triggerbee.shared.pageview(page:title:)` | Log a pageview without running the widget check. |
| `Triggerbee.shared.closeWidget(widgetId:reason:)` | Tell the SDK the visitor closed a widget; replayed to the backend on the next pageload. |
| `Triggerbee.shared.identify(_:properties:)` | Attach an external identifier + custom properties. |
| `Triggerbee.shared.logGoal(name:revenue:)` | Log a goal completion. Persisted locally and replayed on next pageload for realtime audience matching. |
| `Triggerbee.shared.logPurchase(revenue:couponCode:)` | Log a purchase. Both args optional. Revenue is a string so the caller controls formatting. |
| `Triggerbee.shared.setLandingPageQueryParams(_:)` | Persist campaign-attribution params from a deep link / push-notification URL. |
| `Triggerbee.shared.batch(pageviews:goals:purchases:identify:)` | Flush a mixed batch in one round-trip. SDK never calls this itself — exposed for consumer-side queuing. |
| `Triggerbee.shared.widgetUrl(widgetId:)` | Build the widget HTML URL — feed straight into `WKWebView.load(_:)`. |
| `TriggerbeeWidgetView(widgetId:onClosed:onNavigate:)` | Drop-in SwiftUI view: WKWebView + JS bridge + auto `closeWidget` recording. |
| `Triggerbee.shared.sessionContext` | Snapshot of session state (uid, identifier, pageviews). |
| `Triggerbee.shared.sessionContextStream` | `AsyncStream<SessionContext>` for reactive observation. |
| `Triggerbee.shared.disable()` / `enable()` / `isDisabled` | Visitor opt-out kill-switch. When disabled, every SDK call is a silent no-op. See [PRIVACY.md](PRIVACY.md). |

## Error handling

The SDK never traps the host process — there are no `precondition`s in shipped code. Misuse
surfaces as a thrown `TriggerbeeError`, a logged error, or a degraded return value:

| Situation | Result |
|---|---|
| Method called before `configure(_:)` | throws `TriggerbeeError.notInitialized` |
| Tracking method called before `start()` | throws `TriggerbeeError.notStarted` |
| `widgetUrl(widgetId:)` called before `start()` | returns `""` and logs an error |
| `configure(_:)` given a non-positive `siteId` or empty `baseUrl` | logs an error; any previous configuration is left intact |
| Visitor opted out via `disable()` | every method is a silent no-op |

Because several of these are silent by design, pass `OSLogger` while integrating:

```swift
Triggerbee.shared.configure(TriggerbeeConfig(siteId: YOUR_SITE_ID, logger: OSLogger()))
```

## Repo layout

```
triggerbee-sdk-ios/
├── Package.swift
├── Sources/Triggerbee/
│   ├── PrivacyInfo.xcprivacy  — Apple privacy manifest, bundled with the module
│   └── …                      — library source (becomes the linkable module)
└── Tests/TriggerbeeTests/     — XCTest unit tests using URLProtocol-stubbed mocking
```

## Build & test

The package targets iOS only, so `swift build` / `swift test` can't be used — they would build
for the macOS host. Use an iOS Simulator destination:

```bash
# Pick any installed simulator; device names change between Xcode releases.
xcrun simctl list devices available | grep iPhone

xcodebuild test -scheme Triggerbee \
  -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild build -scheme Triggerbee -configuration Release \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

CI runs both on every push and pull request, resolving the simulator name from whatever the
runner's Xcode ships rather than hardcoding a device.

To build the documentation site locally:

```bash
xcodebuild docbuild -scheme Triggerbee -destination 'generic/platform=iOS' \
  -derivedDataPath .derivedData
```

## Privacy

The SDK bundles a [privacy manifest](Sources/Triggerbee/PrivacyInfo.xcprivacy) declaring its
UserDefaults use (required-reason `CA92.1`) and the data types it transmits. Apps embedding it
need no extra declarations on the SDK's behalf — unless they pass additional data types through
`identify(_:properties:)`, which is host-controlled. See [PRIVACY.md](PRIVACY.md).

## License

Apache 2.0
