import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// One-shot snapshot of the device, taken at ``Triggerbee/configure(_:)``.
///
/// Fields are static for the process lifetime (OS version, model, screen size don't change
/// mid-session), so we capture once and reuse on every outgoing request. Locale and time
/// zone *can* change at runtime but it's not worth the per-request cost — consumers who
/// care can re-configure the SDK after a locale change.
enum DeviceInfoCollector {

    static func collect() -> DeviceInfo {
        let (screenWidth, screenHeight) = readScreenSize()
        return DeviceInfo(
            platform: "ios",
            type: detectType(),
            osVersion: readOSVersion(),
            osApiLevel: readOSMajorVersion(),
            sdkVersion: SDKVersion.current,
            manufacturer: "Apple",
            model: readDeviceModel(),
            appVersion: readAppVersion(),
            locale: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
            timeZone: TimeZone.current.identifier,
            screenWidth: screenWidth,
            screenHeight: screenHeight
        )
    }

    private static func detectType() -> String {
        #if canImport(UIKit)
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:
            return "tablet"
        case .phone, .carPlay:
            return "mobile"
        case .tv, .mac:
            return "desktop"
        default:
            return "mobile"
        }
        #else
        return "desktop"
        #endif
    }

    private static func readOSVersion() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
    }

    private static func readOSMajorVersion() -> Int {
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    private static func readDeviceModel() -> String {
        // The hardware identifier (e.g. "iPhone15,3") — closest analogue to Android's Build.MODEL.
        // UIDevice.current.model returns "iPhone"/"iPad" which is too coarse for audience filters.
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { cstr in
                String(cString: cstr)
            }
        }
    }

    private static func readAppVersion() -> String? {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// The screen this app is actually being displayed on.
    ///
    /// `UIScreen.main` is deprecated from iOS 16 because an app can span multiple scenes and run
    /// on an external display, in Stage Manager, or on CarPlay — cases where "the main screen"
    /// isn't the one showing this app. Prefer the active window scene's screen, falling back to
    /// `UIScreen.main` when no scene is available yet (pre-iOS 16, or called before any scene
    /// has connected).
    private static func currentScreen() -> UIScreen? {
        #if os(iOS) || os(tvOS)
        // UIApplication.shared is main-actor state; configure(_:) is documented as an
        // app-startup call, so in practice this runs on the main thread. Off-main callers fall
        // through to UIScreen.main rather than touching UIApplication from the wrong thread.
        if #available(iOS 16.0, tvOS 16.0, *), Thread.isMainThread {
            let scenes = UIApplication.shared.connectedScenes
            let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            if let windowScene = active as? UIWindowScene {
                return windowScene.screen
            }
        }
        #endif
        return UIScreen.main
    }

    private static func readScreenSize() -> (Int, Int) {
        #if canImport(UIKit)
        guard let screen = currentScreen() else { return (0, 0) }
        // `nativeBounds` is already in pixels and is defined against a portrait-up device, so it
        // needs no scale multiplication and — unlike `bounds`, which is orientation-dependent —
        // doesn't go stale when the device rotates. The previous `bounds * scale` froze whichever
        // orientation the app happened to launch in and reported that for the whole session.
        let native = screen.nativeBounds
        return (Int(native.width), Int(native.height))
        #elseif canImport(AppKit)
        if let screen = NSScreen.main {
            let bounds = screen.frame
            let scale = screen.backingScaleFactor
            return (Int(bounds.width * scale), Int(bounds.height * scale))
        }
        return (0, 0)
        #else
        return (0, 0)
        #endif
    }
}
