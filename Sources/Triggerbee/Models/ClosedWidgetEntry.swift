import Foundation

/// In-memory + persisted record of a widget the visitor has closed. Sent on the next
/// pageload/recheck so the backend can apply the matching repetition rule (e.g.
/// "don't show again for 7 days"). SDK-internal — the persistence format and field
/// shape are not part of the public 1.0 contract.
struct ClosedWidgetEntry: Sendable, Equatable {
    let widgetId: Int
    let closedTime: Int64
    let reason: String?
    let pageviews: Int

    /// Encode as `widgetId|closedTime|pageviews|reason` for storage in a string array.
    /// Pipe-separated because reasons are short enum-like strings without pipes.
    func encode() -> String {
        return "\(widgetId)|\(closedTime)|\(pageviews)|\(reason ?? "")"
    }

    static func decode(_ raw: String) -> ClosedWidgetEntry? {
        let parts = raw.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { return nil }
        guard let widgetId = Int(parts[0]) else { return nil }
        guard let closedTime = Int64(parts[1]) else { return nil }
        guard let pageviews = Int(parts[2]) else { return nil }
        let reason = parts[3].isEmpty ? nil : parts[3]
        return ClosedWidgetEntry(widgetId: widgetId, closedTime: closedTime, reason: reason, pageviews: pageviews)
    }
}
