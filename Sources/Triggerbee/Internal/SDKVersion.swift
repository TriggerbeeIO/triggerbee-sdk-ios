import Foundation

/// Single source of truth for the SDK version reported to the backend. Mirrors Android's
/// `BuildConfig.SDK_VERSION`.
///
/// The `publish` workflow refuses to cut a release whose git tag disagrees with this value,
/// so bump it in the same commit as the `CHANGELOG.md` entry — before tagging.
enum SDKVersion {
    static let current: String = "0.1.0"
}
