import Foundation

/// Pure logic behind a deleted sleep night's durable tombstone, so a detected night is not silently
/// re-detected on the next analyze pass (with undo). Tombstones are `"startTs:endTs"` strings in
/// UserDefaults, not a DB table. The undo path restores the row into its original owning namespace,
/// resolved at the Repository layer.
public enum DismissedSleepSpans {

    /// The canonical token for a dismissed window. `endTs` is the night's span so the overlap test still
    /// matches when a re-detected onset drifts.
    public static func token(startTs: Int, endTs: Int) -> String { "\(startTs):\(endTs)" }

    /// Parses a stored token list into `(start, end)` windows. Malformed or non-positive-width entries are
    /// dropped so a corrupt value can never hide everything. Order is preserved.
    public static func windows(from tokens: [String]) -> [(start: Int, end: Int)] {
        tokens.compactMap { s in
            let parts = s.split(separator: ":")
            guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), b > a else { return nil }
            return (a, b)
        }
    }

    /// Adds a token idempotently and returns the new list. The caller persists it.
    public static func adding(startTs: Int, endTs: Int, to tokens: [String]) -> [String] {
        let t = token(startTs: startTs, endTs: endTs)
        guard !tokens.contains(t) else { return tokens }
        var out = tokens
        out.append(t)
        return capped(out)
    }

    /// Removes every copy of the token for `(startTs, endTs)` (the undo / allow-re-detection path).
    public static func removing(startTs: Int, endTs: Int, from tokens: [String]) -> [String] {
        let t = token(startTs: startTs, endTs: endTs)
        return tokens.filter { $0 != t }
    }

    /// True when `[sessionStart, sessionEnd)` overlaps any dismissed window (half-open `<` test). Overlap, not
    /// exact startTs, because a re-detected onset drifts as more raw data arrives.
    public static func isSuppressed(sessionStart: Int, sessionEnd: Int,
                                    windows: [(start: Int, end: Int)]) -> Bool {
        windows.contains { sessionStart < $0.end && $0.start < sessionEnd }
    }

    /// Whether deleting a night writes a tombstone. Detected nights do; user-created/edited nights never get
    /// re-detected, so a tombstone would only block a real future night overlapping them.
    public static func writesTombstoneOnDelete(userEdited: Bool) -> Bool { !userEdited }

    /// Hard cap on the tombstone list. There is no age prune (it would resurrect nights while banked raw
    /// still covers them); keep the newest by end-time.
    public static let hardCap = 500

    static func capped(_ tokens: [String]) -> [String] {
        guard tokens.count > hardCap else { return tokens }
        // Drop the OLDEST by end-time. Malformed tokens sort last (endTs 0) and are dropped first.
        func endTs(_ s: String) -> Int {
            let parts = s.split(separator: ":")
            return parts.count == 2 ? (Int(parts[1]) ?? 0) : 0
        }
        return Array(tokens.sorted { endTs($0) > endTs($1) }.prefix(hardCap))
    }
}
