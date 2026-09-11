// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Triggerbee",
    // iOS only. The package previously advertised macOS/tvOS/watchOS, but CI never compiled for
    // them and DeviceInfoCollector reports `platform: "ios"` unconditionally, so the claim was
    // untested. Widening platforms later is a non-breaking minor; narrowing them is not — which
    // is why this happens before the first tag rather than after. The `os(macOS)` / `os(tvOS)`
    // branches are left in the source so re-widening stays cheap.
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "Triggerbee",
            targets: ["Triggerbee"]
        ),
    ],
    targets: [
        .target(
            name: "Triggerbee",
            path: "Sources/Triggerbee",
            // Apple requires a third-party SDK that collects data or touches a required-reason
            // API to ship its own privacy manifest — the host app's manifest cannot cover the
            // SDK's behaviour. `.copy` (not `.process`) so the file lands at the resource-bundle
            // root byte-for-byte, which is where the privacy report generator looks for it.
            resources: [
                .copy("PrivacyInfo.xcprivacy"),
            ]
        ),
        .testTarget(
            name: "TriggerbeeTests",
            dependencies: ["Triggerbee"],
            path: "Tests/TriggerbeeTests"
        ),
    ]
)
