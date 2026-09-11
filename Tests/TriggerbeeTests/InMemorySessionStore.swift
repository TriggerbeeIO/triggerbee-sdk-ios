import Foundation
@testable import Triggerbee

/// Test-only ``SessionStore`` backed by an in-memory dictionary so SdkClient tests don't need
/// a real UserDefaults suite. Actor-isolated to mirror the production store's serialization.
actor InMemorySessionStore: SessionStore {
    private var uid: Int64?
    private var identifier: String?
    private var closedWidgets: [ClosedWidgetEntry] = []
    private var audienceState: VisitorAudienceState = VisitorAudienceState()

    func getUid() async -> Int64? { return uid }
    func setUid(_ uid: Int64) async { self.uid = uid }

    func getIdentifier() async -> String? { return identifier }
    func setIdentifier(_ identifier: String) async { self.identifier = identifier }

    func getClosedWidgets() async -> [ClosedWidgetEntry] { return closedWidgets }
    func setClosedWidgets(_ entries: [ClosedWidgetEntry]) async { self.closedWidgets = entries }

    func getAudienceState() async -> VisitorAudienceState { return audienceState }
    func setAudienceState(_ state: VisitorAudienceState) async { self.audienceState = state }
}
