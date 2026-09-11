import Foundation

/// Persistent visitor state — uid, identifier, closed widgets, and audience-relevant state
/// (goals, landing-page query params) used for realtime audience matching before the data
/// lands in the Visitors database. Extracted as a protocol so tests can swap in an
/// in-memory impl without writing to UserDefaults.
protocol SessionStore: Sendable {
    func getUid() async -> Int64?
    func setUid(_ uid: Int64) async
    func getIdentifier() async -> String?
    func setIdentifier(_ identifier: String) async
    func getClosedWidgets() async -> [ClosedWidgetEntry]
    func setClosedWidgets(_ entries: [ClosedWidgetEntry]) async
    func getAudienceState() async -> VisitorAudienceState
    func setAudienceState(_ state: VisitorAudienceState) async
}

/// Production ``SessionStore`` backed by `UserDefaults` under a dedicated suite name.
/// All reads/writes hop to a serial actor so concurrent SDK calls don't race UserDefaults.
actor UserDefaultsSessionStore: SessionStore {
    private let defaults: UserDefaults
    private let uidKey = "uid"
    private let identifierKey = "identifier"
    private let closedWidgetsKey = "closed_widgets"
    private let audienceStateKey = "audience_state"

    init(suiteName: String = "com.triggerbee.sdk") {
        // Fallback to standard if a suite can't be created (sandboxed restrictions, etc.).
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    func getUid() -> Int64? {
        // UserDefaults stores numbers as NSNumber under the hood; integer(forKey:) returns 0 for missing
        // *and* for explicitly-stored 0, so use object(forKey:) to distinguish.
        guard let raw = defaults.object(forKey: uidKey) else { return nil }
        guard let number = raw as? NSNumber else { return nil }
        let value = number.int64Value
        return value != 0 ? value : nil
    }

    func setUid(_ uid: Int64) {
        defaults.set(NSNumber(value: uid), forKey: uidKey)
    }

    func getIdentifier() -> String? {
        guard let value = defaults.string(forKey: identifierKey) else { return nil }
        return value.isEmpty ? nil : value
    }

    func setIdentifier(_ identifier: String) {
        defaults.set(identifier, forKey: identifierKey)
    }

    func getClosedWidgets() -> [ClosedWidgetEntry] {
        guard let raw = defaults.array(forKey: closedWidgetsKey) as? [String] else { return [] }
        return raw.compactMap(ClosedWidgetEntry.decode)
    }

    func setClosedWidgets(_ entries: [ClosedWidgetEntry]) {
        defaults.set(entries.map { $0.encode() }, forKey: closedWidgetsKey)
    }

    func getAudienceState() -> VisitorAudienceState {
        guard let raw = defaults.string(forKey: audienceStateKey),
              let data = raw.data(using: .utf8) else {
            return VisitorAudienceState()
        }
        do {
            return try JSONDecoder().decode(VisitorAudienceState.self, from: data)
        } catch {
            // Schema drift from a previous SDK version — drop the stale blob, start fresh.
            return VisitorAudienceState()
        }
    }

    func setAudienceState(_ state: VisitorAudienceState) {
        guard let data = try? JSONEncoder().encode(state),
              let raw = String(data: data, encoding: .utf8) else {
            return
        }
        defaults.set(raw, forKey: audienceStateKey)
    }
}
