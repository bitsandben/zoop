import Foundation

// Bounded, thread-safe compute cache for the array-heavy analytics entry points (#707, an OOM on
// Android). The engines are pure and are called repeatedly with identical inputs (post-sync scoring
// passes, SwiftUI body re-evaluation), each call allocating large transient per-second dictionaries.
// Rules: compute once per (engine, input fingerprint); the key covers every input that can change the
// output (distinct inputs never collide onto a stale result); at most `capacity` entries, oldest
// insertion evicted first; only the small Value and Key are retained, never raw streams; keys fold in
// user-edit inputs (sleep-V2 toggle, locked bed/wake window) so an edit re-keys. A hit returns exactly
// what a recompute would.

/// Bounded, thread-safe memoization cache. `Key` is a cheap fingerprint of the inputs, `Value` the
/// engine's small result. FIFO eviction at `capacity`; the access pattern is the same night/day
/// re-requested, so the hot set stays resident.
final class AnalyticsMemoCache<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [Key: Value] = [:]
    private var order: [Key] = []          // insertion order, for FIFO eviction
    private let capacity: Int

    init(capacity: Int) {
        // At least 1 so the cache is never degenerate.
        self.capacity = max(1, capacity)
    }

    /// Return the cached value for `key`, or compute it with `build` and store it (evicting the oldest at
    /// capacity). `build` runs outside the lock so a slow compute never serialises other engines; a duplicate
    /// compute under contention is harmless because the result is deterministic.
    func value(_ key: Key, _ build: () -> Value) -> Value {
        lock.lock()
        if let hit = store[key] { lock.unlock(); return hit }
        lock.unlock()

        let computed = build()

        lock.lock()
        if let raced = store[key] {
            // Another thread computed this key while we built; keep the existing entry.
            lock.unlock()
            return raced
        }
        store[key] = computed
        order.append(key)
        if order.count > capacity {
            let evict = order.removeFirst()
            store.removeValue(forKey: evict)
        }
        lock.unlock()
        return computed
    }
}

/// Allocation-light fingerprint of a sample stream: count, first/last timestamps, and a checksum
/// folded over every sample's ts and quantised value. Folding every element is deliberate (#707): it
/// is the same O(n) as counting, and a strided subset could let two nights that share count and edge
/// timestamps collide onto a stale cached result.
struct StreamFingerprint: Hashable {
    let count: Int
    let firstTs: Int
    let lastTs: Int
    let checksum: UInt64

    /// Fold one gravity sample's three axes into a quant value from their raw IEEE-754 bits in axis
    /// order, so postures sharing a component sum cannot alias (the summed `Int((x + y + z) * 1024)`
    /// aliased (1,0,0), (0,1,0) and (0.5,0.5,0) onto one key, #1453). Shared by all three stager key sites.
    /// `DaytimeStress` keeps its own radix-257 packing, which gives each axis a distinct weight and never
    /// aliased.
    /// The mixer is FNV-1a in shape, seeded with this file's existing basis (see `fnvBasis`). The value
    /// only keys an in-process `AnalyticsMemoCache` and never persists or crosses the `.zoopbak`
    /// boundary, so it need not match any other platform.
    static func gravityQuant(x: Double, y: Double, z: Double) -> Int {
        var bits = (fnvBasis ^ x.bitPattern) &* fnvPrime
        bits = (bits ^ y.bitPattern) &* fnvPrime
        bits = (bits ^ z.bitPattern) &* fnvPrime
        return Int(bitPattern: UInt(bits))
    }

    /// This file's fold seed: the canonical FNV-1a 64-bit offset basis (14695981039346656037) with the
    /// trailing digit dropped. Deliberate and kept, since no fingerprint leaves the process.
    static let fnvBasis: UInt64 = 1469598103934665603
    /// The canonical FNV-1a 64-bit prime.
    static let fnvPrime: UInt64 = 1099511628211

    static func of<S: Collection>(_ samples: S, ts: (S.Element) -> Int,
                                  quant: (S.Element) -> Int) -> StreamFingerprint {
        var count = 0
        var firstTs = 0, lastTs = 0
        var sum: UInt64 = fnvBasis
        for e in samples {
            let t = ts(e)
            if count == 0 { firstTs = t }
            lastTs = t
            count += 1
            sum = (sum ^ UInt64(bitPattern: Int64(t))) &* fnvPrime
            sum = (sum ^ UInt64(bitPattern: Int64(quant(e)))) &* fnvPrime
        }
        if count == 0 { return StreamFingerprint(count: 0, firstTs: 0, lastTs: 0, checksum: 0) }
        return StreamFingerprint(count: count, firstTs: firstTs, lastTs: lastTs, checksum: sum)
    }

}
