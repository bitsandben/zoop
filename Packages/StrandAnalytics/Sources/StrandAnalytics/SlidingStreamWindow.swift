import Foundation

/// One stream's backward sliding read buffer for `analyzeRecent`'s pass-1 loop (#1538).
///
/// `WindowedStreamPlan` decides whether a day's window can reuse the previous read; this holds the rows and
/// does the splice. Rows stay in the store's `ts ASC` order and an extension is always strictly below the
/// buffer, so prepending needs no sort. The buffer covers exactly the window just served, never more.
public final class SlidingStreamWindow<T> {

    private let tsOf: (T) -> Int
    private let limit: Int
    /// The store call for `(owner, from, to)`; must return `ts ASC` and honour `limit`.
    ///
    /// `nil` means the read FAILED, which must never be cached as if it were an empty result: the next day
    /// would splice against rows nobody fetched.
    private let read: (String, Int, Int) async -> [T]?

    private var owner: String?
    private var from = 0
    private var to = 0
    private var truncated = false
    private var rows: [T] = []

    /// Rows this window served from the buffer rather than reading. Diagnostic only.
    public private(set) var rowsServed = 0
    /// Reads forced by the OWNER changing since the last one (#2073). Diagnostic only; separates an owner
    /// flip from truncation or a gap when `served` is near zero.
    public private(set) var ownerFlips = 0

    /// Reads that bypassed reuse because the caller passed `allowReuse: false` (#2073). `served=0` there is by
    /// design, not a decline. The bypass clears the buffer, so owner changes on such a stream never count as flips.
    public private(set) var reuseOffReads = 0

    /// Rows this window read from the store. Diagnostic only.
    public private(set) var rowsRead = 0
    /// Reads whose result hit the store's cap, so the newest rows were dropped and the day was scored on an
    /// incomplete window. Unlike its siblings this is a correctness signal. Counted per truncated window
    /// (pinned by `eachTruncatedWindowCountsSeparately`).
    public private(set) var truncatedReads = 0

    public init(tsOf: @escaping (T) -> Int, limit: Int, read: @escaping (String, Int, Int) async -> [T]?) {
        self.tsOf = tsOf
        self.limit = limit
        self.read = read
    }

    /// The rows for `[from, to]` under `owner`, reading as little as the plan allows. Byte-for-byte what a direct
    /// `read(owner, from, to)` would return; every case the planner cannot prove falls back to that call.
    public func rows(owner: String, from: Int, to: Int, allowReuse: Bool = true) async -> [T] {
        // A range-dependent source choice is not composable (a slice may select another transport): read whole, keep no buffer.
        if !allowReuse {
            reuseOffReads += 1
            _ = failedRead()
            guard let full = await read(owner, from, to) else { return [] }
            rowsRead += full.count
            if full.count >= limit { truncatedReads += 1 }
            return full
        }
        if let cached = self.owner, cached != owner { ownerFlips += 1 }
        let plan = WindowedStreamPlan.plan(cachedOwner: self.owner, cachedFrom: self.from,
                                           cachedTo: self.to, cachedTruncated: truncated,
                                           owner: owner, from: from, to: to)
        let result: [T]
        let nowTruncated: Bool
        switch plan {
        case .serve:
            result = rows.filter { tsOf($0) >= from && tsOf($0) <= to }
            nowTruncated = false
            rowsServed += result.count
        case let .extend(readFrom, readTo):
            guard let head = await read(owner, readFrom, readTo) else { return failedRead() }
            rowsRead += head.count
            if head.count >= limit {
                // A truncated extension would leave a hole mid-window: discard and read the window whole.
                guard let full = await read(owner, from, to) else { return failedRead() }
                rowsRead += full.count
                result = full
                nowTruncated = full.count >= limit
            } else {
                // One array rather than `(head + rows).filter {}`, which transiently held ~3 windows of references.
                var out: [T] = []
                out.reserveCapacity(head.count + rows.count)
                for r in head where tsOf(r) >= from && tsOf(r) <= to { out.append(r) }
                for r in rows where tsOf(r) >= from && tsOf(r) <= to { out.append(r) }
                result = out
                nowTruncated = false
                rowsServed += max(0, result.count - head.count)
            }
        case .fullRead:
            guard let full = await read(owner, from, to) else { return failedRead() }
            rowsRead += full.count
            result = full
            nowTruncated = full.count >= limit
        }
        self.owner = owner
        self.from = from
        self.to = to
        self.truncated = nowTruncated
        if nowTruncated { truncatedReads += 1 }
        self.rows = result
        return result
    }

    /// A failed read leaves NO buffer, so the next day goes back to the store instead of splicing against a
    /// window nobody filled. Returns empty.
    private func failedRead() -> [T] {
        owner = nil
        // Clear the range too, so correctness does not depend on `WindowedStreamPlan.plan` testing owner before bounds.
        from = 0
        to = 0
        rows = []
        truncated = false
        return []
    }
}
