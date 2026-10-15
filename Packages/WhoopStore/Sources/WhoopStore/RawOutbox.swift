#if canImport(Compression)
import Foundation
import Compression
import GRDB
import WhoopProtocol

public struct RawBatchMeta: Equatable {
    public let batchId: String
    public let deviceId: String
    public let clockRef: ClockRef
    public let capturedAt: Int
    public let startTs: Int
    public let endTs: Int
    public let frameCount: Int
    public let byteSize: Int
    public init(batchId: String, deviceId: String, clockRef: ClockRef, capturedAt: Int,
                startTs: Int, endTs: Int, frameCount: Int, byteSize: Int) {
        self.batchId = batchId; self.deviceId = deviceId; self.clockRef = clockRef
        self.capturedAt = capturedAt; self.startTs = startTs; self.endTs = endTs
        self.frameCount = frameCount; self.byteSize = byteSize
    }
}

extension WhoopStore {
    // MARK: - frame (de)serialization
    // Layout: [count u32 LE]{ [len u32 LE][bytes] } x count, zlib-compressed as a whole.

    static func packFrames(_ frames: [[UInt8]]) -> Data {
        var buf = Data()
        func appendU32(_ v: Int) {
            let u = UInt32(v)
            buf.append(UInt8(u & 0xFF)); buf.append(UInt8((u >> 8) & 0xFF))
            buf.append(UInt8((u >> 16) & 0xFF)); buf.append(UInt8((u >> 24) & 0xFF))
        }
        appendU32(frames.count)
        for f in frames {
            appendU32(f.count)
            buf.append(contentsOf: f)
        }
        return buf
    }

    static func unpackFrames(_ data: Data) -> [[UInt8]] {
        let bytes = [UInt8](data)
        var off = 0
        func readU32() -> Int? {
            guard off + 4 <= bytes.count else { return nil }
            let v = Int(bytes[off]) | (Int(bytes[off + 1]) << 8)
                | (Int(bytes[off + 2]) << 16) | (Int(bytes[off + 3]) << 24)
            off += 4
            return v
        }
        guard let count = readU32() else { return [] }
        var out: [[UInt8]] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard let len = readU32(), off + len <= bytes.count else { break }
            out.append(Array(bytes[off..<off + len]))
            off += len
        }
        return out
    }

    // MARK: - zlib helpers using Apple Compression framework

    /// Decompresses a blob from `zlibCompressWithLength`: a UInt32 LE uncompressed length, then the zlib payload.
    static func zlibDecompressWithLength(_ input: Data) throws -> Data {
        guard input.count >= 4 else { throw CocoaError(.fileReadUnknown) }
        let n = Int(input[input.startIndex])
            | (Int(input[input.startIndex + 1]) << 8)
            | (Int(input[input.startIndex + 2]) << 16)
            | (Int(input[input.startIndex + 3]) << 24)
        let compressed = input.dropFirst(4)
        // n == 0 means packFrames returned empty data; return empty.
        guard n > 0 else { return Data() }
        var dst = [UInt8](repeating: 0, count: n)
        let written: Int = compressed.withUnsafeBytes { src in
            guard let srcPtr = src.baseAddress else { return 0 }
            return compression_decode_buffer(&dst, n, srcPtr, compressed.count, nil, COMPRESSION_ZLIB)
        }
        // If written != n the blob is genuinely corrupt (not a sizing issue).
        guard written == n else { throw CocoaError(.fileReadCorruptFile) }
        return Data(dst)
    }

    /// Compresses `input` and prepends its uncompressed length as a UInt32 LE.
    static func zlibCompressWithLength(_ input: Data) throws -> Data {
        let sourceSize = input.count
        let dstCapacity = max(64, sourceSize * 2 + 64)
        var dst = [UInt8](repeating: 0, count: dstCapacity)
        let written: Int = input.withUnsafeBytes { src in
            guard let srcPtr = src.baseAddress else { return 0 }
            return compression_encode_buffer(&dst, dstCapacity, srcPtr, sourceSize, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { throw CocoaError(.fileWriteUnknown) }
        let u = UInt32(sourceSize)
        var blob = Data(capacity: 4 + written)
        blob.append(UInt8(u & 0xFF)); blob.append(UInt8((u >> 8) & 0xFF))
        blob.append(UInt8((u >> 16) & 0xFF)); blob.append(UInt8((u >> 24) & 0xFF))
        blob.append(contentsOf: dst[0..<written])
        return blob
    }

    // MARK: - Public API

    /// Compress raw frames into the outbox and store batch meta.
    public func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {
        let packed = WhoopStore.packFrames(frames)
        let blob = try WhoopStore.zlibCompressWithLength(packed)
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO rawBatch
                    (batchId, deviceId, capturedAt, deviceClockRef, wallClockRef,
                     startTs, endTs, frameCount, byteSize, framesBlob, syncedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                ON CONFLICT(batchId) DO NOTHING
                """, arguments: [
                    meta.batchId, meta.deviceId, meta.capturedAt,
                    meta.clockRef.device, meta.clockRef.wall,
                    meta.startTs, meta.endTs, meta.frameCount, meta.byteSize, blob])
        }
    }

    /// Decompress and return the exact frame bytes for a batch (empty if unknown).
    public func rawFrames(batchId: String) async throws -> [[UInt8]] {
        let row: Row? = try syncRead { db in
            try Row.fetchOne(db,
                sql: "SELECT framesBlob FROM rawBatch WHERE batchId = ?",
                arguments: [batchId])
        }
        guard let row = row else { return [] }
        let blob: Data = row["framesBlob"]
        let raw = try WhoopStore.zlibDecompressWithLength(blob)
        return WhoopStore.unpackFrames(raw)
    }

    private static func metaFromRow(_ row: Row) -> RawBatchMeta {
        RawBatchMeta(
            batchId: row["batchId"], deviceId: row["deviceId"],
            clockRef: ClockRef(device: row["deviceClockRef"], wall: row["wallClockRef"]),
            capturedAt: row["capturedAt"], startTs: row["startTs"], endTs: row["endTs"],
            frameCount: row["frameCount"], byteSize: row["byteSize"])
    }

    /// Un-synced batches (syncedAt IS NULL), oldest first, capped at `limit`.
    public func pendingRawBatches(limit: Int) async throws -> [RawBatchMeta] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT batchId, deviceId, capturedAt, deviceClockRef, wallClockRef,
                       startTs, endTs, frameCount, byteSize
                FROM rawBatch
                WHERE syncedAt IS NULL
                ORDER BY capturedAt ASC
                LIMIT ?
                """, arguments: [limit]).map(WhoopStore.metaFromRow)
        }
    }

    /// Marks a batch synced (unix seconds). Has no production caller by design: Zoop has no sync target,
    /// so this is only the hook for a possible future on-device export lane.
    public func markRawBatchSynced(batchId: String, at: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: "UPDATE rawBatch SET syncedAt = ? WHERE batchId = ?",
                           arguments: [at, batchId])
        }
    }
}

extension WhoopStore {
    /// Prunes raw outbox rows and returns the number of rawBatch rows deleted.
    ///
    /// Policy 1 (dormant in a shipping build): delete synced batches whose `syncedAt` is older than
    /// `now - keepWindowSeconds`. `syncedAt` is only set by `markRawBatchSynced`, which has no caller,
    /// so this cannot fire; it is kept for a future server-free export lane.
    ///
    /// Policy 2 (the real growth bound): cap total raw footprint at `maxUnsyncedBytes`. Walk batches
    /// newest-first summing `byteSize` and delete every row once the total exceeds the cap, dropping the
    /// oldest raw. Raw is transient: decoded streams are persisted before the raw batch is enqueued, so
    /// eviction never loses a decoded metric. Without it an experimental capture toggle grew to 19 GB.
    ///
    /// - Parameters:
    ///   - now: Current unix-second timestamp used to compute the synced-aging cutoff.
    ///   - keepWindowSeconds: Synced batches older than `now - keepWindowSeconds` are removed.
    ///   - maxUnsyncedBytes: Total raw-footprint cap; oldest batches beyond it are evicted.
    @discardableResult
    public func pruneRaw(now: Int, keepWindowSeconds: Int, maxUnsyncedBytes: Int) async throws -> Int {
        try syncWrite { db in
            var pruned = 0
            let cutoff = now - keepWindowSeconds
            try db.execute(sql: """
                DELETE FROM rawBatch WHERE syncedAt IS NOT NULL AND syncedAt < ?
                """, arguments: [cutoff])
            pruned += db.changesCount

            // Policy 2: newest-first running sum of byteSize; older rows past the cap are dropped. rowid keeps
            // the cutoff stable across ties on capturedAt.
            let rows = try Row.fetchAll(db, sql: """
                SELECT rowid, byteSize FROM rawBatch ORDER BY capturedAt DESC, rowid DESC
                """)
            var cumulative = 0
            var evict: [Int64] = []
            for row in rows {
                let size: Int = row["byteSize"]
                let rowid: Int64 = row["rowid"]
                cumulative += size
                if cumulative > maxUnsyncedBytes {
                    evict.append(rowid)
                }
            }
            if !evict.isEmpty {
                let placeholders = evict.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM rawBatch WHERE rowid IN (\(placeholders))",
                    arguments: StatementArguments(evict))
                pruned += db.changesCount
            }
            return pruned
        }
    }

    // MARK: - Test helper
    public func allBatchIdsForTest() async throws -> [String] {
        try syncRead { db in
            try String.fetchAll(db, sql: "SELECT batchId FROM rawBatch ORDER BY capturedAt ASC")
        }
    }
}
#endif
