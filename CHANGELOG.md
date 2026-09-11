# Changelog

All notable changes to the Triggerbee iOS SDK are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-08-21

First public release. Native iOS SDK for the Triggerbee platform.

### Features

- **Configure once, use anywhere** — `Triggerbee.shared.configure(TriggerbeeConfig(siteId: …))`
  configures the singleton; the rest of the API hangs off `Triggerbee.shared`.
- **Visitor identifier** — `start()` mints a `SystemRandomNumberGenerator`-derived 64-bit `uid`
  on first launch and persists it in UserDefaults. Generated client-side, works offline, never
  round-trips through the backend. Capped to `Number.MAX_SAFE_INTEGER` so it survives the
  WebView's `parseInt(cookie)` round-trip.
- **Page load + widget check** — `pageload(page:title:secondsOnPage:)` logs the pageview *and*
  returns the widgets eligible for this visit in one round-trip.
- **Re-check** — `recheck(page:secondsOnPage:)` re-evaluates widget eligibility on the same page
  without logging a new pageview.
- **Visitor events** — `identify(_:properties:)`, `logGoal(name:revenue:)`,
  `logPurchase(revenue:couponCode:)`, `pageview(page:title:)`,
  `setLandingPageQueryParams(_:)`, plus `batch(pageviews:goals:purchases:identify:)` to fold
  several events into a single request.
- **Widget rendering** — `widgetUrl(widgetId:)` builds the URL ready to feed into
  `WKWebView.load(_:)`; `TriggerbeeWidgetView` is a drop-in SwiftUI view that hosts the WebView,
  handles the JS bridge (bounds, navigation, close), applies a 3-second engine timeout, and
  records close events automatically.
- **Closed-widget state** — `closeWidget(widgetId:reason:)` persists locally and replays on the
  next pageload so the backend can apply the matching repetition rule.
- **Device snapshot** — `DeviceInfo` is collected once at `configure(_:)` and sent on every
  widget check, so audience rules can match without inferring from a User-Agent.
- **Visitor opt-out** — `disable()` / `enable()` / `isDisabled` is a kill-switch; while disabled
  every public method is a silent no-op and no network requests are made. See
  [PRIVACY.md](PRIVACY.md).
- **Session state** — `sessionContext` for a synchronous, non-blocking snapshot and
  `sessionContextStream` (`AsyncStream<SessionContext>`) for reactive observation.
- **Pluggable logger** — `TriggerbeeLogger` protocol; default `NoOpLogger` ships zero log output
  in production. Pass `OSLogger` to forward to `os_log` / Console.app.
- **Structured errors** — `TriggerbeeError` (`notInitialized`, `notStarted`,
  `httpError(code:body:)`, `networkError`, `serializationError`); no silent catch.
- **Privacy manifest** — bundles `PrivacyInfo.xcprivacy` declaring the UserDefaults
  required-reason API (`CA92.1`) and the data types transmitted, so host apps pass App Store
  Connect validation without adding declarations on the SDK's behalf.

### Behaviour notes

- **The SDK never traps the host process.** Misuse is reported through `TriggerbeeError`, a
  logged error, or a degraded return value — never `precondition`. Calling a tracking method
  before `start()` throws `TriggerbeeError.notStarted`; `widgetUrl(widgetId:)` returns `""`
  and logs; an invalid `TriggerbeeConfig` is rejected by `configure(_:)` with a logged error and
  leaves any previous configuration intact. Pass `OSLogger` while integrating so these are
  visible rather than silent.
- `sessionContext` is a synchronous read served from a cache that every async method refreshes.
  It never blocks the calling thread, and reads before `start()` completes return an empty
  context rather than waiting.
- A trailing `/` on `TriggerbeeConfig.baseUrl` is stripped rather than rejected.

### Requirements

- iOS 15+
- Swift 5.9+ toolchain, Xcode 15+
- No third-party dependencies

### Installation

Swift Package Manager — there is no separate registry, so the git tag is the release:

```swift
.package(url: "https://github.com/TriggerbeeIO/triggerbee-sdk-ios.git", from: "0.1.0")
```
