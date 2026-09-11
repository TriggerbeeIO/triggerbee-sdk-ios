# Privacy

The Triggerbee iOS SDK is a thin HTTP client that sends data from your app to Triggerbee's
backend. This document is the canonical list of what the SDK collects, where it sends it,
and how a host app can give visitors a kill-switch.

## What the SDK collects

### Visitor identifier (`uid`)
- A 64-bit positive integer minted by `Triggerbee.shared.start()` using
  `SystemRandomNumberGenerator` on first launch and persisted in the app's UserDefaults.
  Reused on every subsequent launch.
- The value is generated **client-side**, never round-tripped through the backend, so the
  SDK works offline on first launch.
- Not derived from any device identifier (IDFA, IDFV, hardware UUIDs are never read) and
  carries no cross-app correlation.

### Caller-supplied event payloads
The host app explicitly passes everything in these calls; the SDK does not read app state
or page contents on its own.

> **For app developers:** because `identify(_:properties:)` and `setLandingPageQueryParams(_:)`
> carry whatever *you* put in them, the SDK's privacy manifest declares them as
> `NSPrivacyCollectedDataTypeOtherDataTypes`. If you pass a data type Apple categorises
> separately — health, financial info, precise location — declare it in your own app's
> `PrivacyInfo.xcprivacy` as well.

- `pageload(page:title:secondsOnPage:)` / `pageview(page:title:)` — string path + title.
- `logGoal(name:revenue:)` — goal name + optional revenue string.
- `logPurchase(revenue:couponCode:)` — both optional.
- `identify(_:properties:)` — identifier (typically email or phone) + optional flat
  `[String: String]` of custom properties.
- `setLandingPageQueryParams(_:)` — campaign-attribution params.

### Device snapshot (`DeviceInfo`)
Built once at `Triggerbee.shared.configure(_:)` from `UIDevice` / `Bundle` / `Locale` /
`utsname()`. No runtime permission is required for any of these.

| Field | Source | Example |
|---|---|---|
| `platform` | constant | `"ios"` |
| `type` | `UIDevice.current.userInterfaceIdiom` | `"mobile"` / `"tablet"` / `"desktop"` |
| `osVersion` | `UIDevice.current.systemVersion` | `"17.3.1"` |
| `osApiLevel` | `ProcessInfo.operatingSystemVersion.majorVersion` | `17` |
| `sdkVersion` | bundled `SDKVersion.current` | `"0.1.0"` |
| `manufacturer` | constant | `"Apple"` |
| `model` | `utsname.machine` | `"iPhone15,3"` |
| `appVersion` | host app's `CFBundleShortVersionString` | `"1.4.2"` |
| `locale` | `Locale.current.identifier` | `"en-US"` |
| `timeZone` | `TimeZone.current.identifier` | `"Europe/Stockholm"` |
| `screenWidth` / `screenHeight` | `nativeBounds` of the active window scene's screen (physical pixels, portrait-fixed) | `1206` / `2622` |

### Server-observed metadata
The backend additionally records the request's IP address for rate-limiting, geo-resolution,
and fraud detection. This is observed by Triggerbee's edge, not collected by the SDK itself,
so it is not declared in the SDK's privacy manifest. If your app's own App Store privacy
disclosures cover coarse location, account for the geo-resolution step there.

## What the SDK does NOT collect

- Device identifiers: IDFA, IDFV, vendor identifiers, hardware UUIDs.
- Location (no `NSLocationWhenInUseUsageDescription` requested).
- Contacts, calendar, photos, microphone, camera, or any other permission-gated scope.
- Pedometer, motion sensors, accessibility events, or any background runtime telemetry.
- Any data the host app has not explicitly passed to a Triggerbee call.

## What the SDK persists locally

The SDK writes to its own `UserDefaults` suite (`com.triggerbee.sdk`) under the host app's
sandbox. Cleared when the user uninstalls the app or clears its data.

- The visitor `uid`.
- The identifier set via `identify(_:properties:)`.
- The list of widgets the visitor has closed.
- Audience state: goals logged this visit, landing-page query params.

## Privacy manifest

The SDK ships [`Sources/Triggerbee/PrivacyInfo.xcprivacy`](Sources/Triggerbee/PrivacyInfo.xcprivacy),
bundled with the module so Xcode picks it up in the host app's privacy report. Apple requires
a third-party SDK that collects data or uses a required-reason API to carry its own manifest —
the host app's file cannot cover the SDK's behaviour. It declares:

| Declaration | Value | Why |
|---|---|---|
| `NSPrivacyTracking` | `false` | No IDFA/IDFV or other device identifier is read, and the `uid` is per app install, so there is no cross-app or cross-vendor correlation. |
| `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1` | The SDK persists visitor state in its own suite inside the host app's container. No App Group is used. |
| Collected data types | Email address, phone number, user ID, product interaction, purchase history, other | See the sections above for exactly which call contributes each. All marked *linked to the user*, none marked *used for tracking*. |

To confirm it reached your build: **Product → Archive**, then **Generate Privacy Report** on the
archive — Triggerbee should appear with the declarations above.

## Where data goes

All HTTP requests target the `baseUrl` configured in `TriggerbeeConfig`. For Triggerbee
production deployments this is `https://api.triggerbee.com`.

## Visitor opt-out

Call `Triggerbee.shared.disable()` to silence every subsequent SDK call for the rest of
the process lifetime. All public methods become no-ops; no network requests are made.

```swift
// In your consent flow, when the user declines tracking:
Triggerbee.shared.disable()
```

`Triggerbee.shared.enable()` reverses it. The flag is in-memory, so apps that want it to
persist across launches should set it themselves on every cold start based on the user's
stored consent choice.

`disable()` does **not** clear persisted SDK state — it leaves the `uid` and identifier
in place so the same session can resume after `enable()`. For a hard erasure use the
"Delete App" / data-clearing flows in iOS or invoke Triggerbee's backend GDPR-deletion
endpoint with the visitor's identifier.

## Contact

Questions or data-subject requests: <support@triggerbee.com>.
