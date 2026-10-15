import Foundation

/// Selects which Oura diagnostics files a Test Centre export ships.
///
/// Each dump keeps a per-session generation ring: the live file `oura-<kind>-<ringId>.jsonl` is the
/// current session and finished sessions roll into `…jsonl.1` (newest retained) … `…jsonl.N`.
/// Largest-wins is the wrong criterion because the wake drain flushes a whole night in one burst, so
/// the biggest generation is often not the one holding the night. Instead the generations are
/// concatenated oldest to newest and the bundle cap, which trims from the front, keeps the newest tail.
///
/// One merged entry rather than one per generation, because extra entries would shrink every other
/// stream's share of the 20 MB cap. Merging is safe: generations are disjoint sessions, every line
/// carries its own `utc`/`iso`, and the offline reframer dedups by `(tag, ring-time)`.
public enum OuraSidecarGenerations {

    /// Bundle entry name for a sidecar kind. The ring id is dropped because redaction scrubs content, not file names.
    public static func entryName(kind: String) -> String { "oura-\(kind).jsonl" }

    /// Classifies a diagnostics filename as `(kind, generation)`, or nil when it is not one of `kinds`.
    ///
    /// `generation` is 0 for the live file and `n` for `…jsonl.n`; smaller is more recent (1 is the
    /// newest retained). Only the ring's exact shape matches: `oura-raw.txt`, `oura-raw-<id>.jsonl.bak`
    /// and a bare `oura-raw.jsonl` are nil.
    public static func classify(filename: String, kinds: [String]) -> (kind: String, generation: Int)? {
        for kind in kinds where filename.hasPrefix("oura-\(kind)-") {
            guard let range = filename.range(of: ".jsonl") else { continue }
            let tail = filename[range.upperBound...]      // "" for the live file, ".3" for a generation
            if tail.isEmpty { return (kind, 0) }
            guard tail.hasPrefix("."), tail.count > 1 else { continue }
            let digits = tail.dropFirst()
            guard digits.allSatisfy(\.isNumber), let n = Int(digits) else { continue }
            return (kind, n)
        }
        return nil
    }

    /// One bundle entry and the files that make it up, already in concatenation order.
    public struct Plan: Equatable {
        /// Normalized bundle entry name, e.g. `oura-raw.jsonl`.
        public let entryName: String
        /// Filenames to concatenate, **OLDEST → NEWEST**. Never empty.
        public let files: [String]
        public init(entryName: String, files: [String]) {
            self.entryName = entryName
            self.files = files
        }
    }

    /// Plans the merge for every sidecar kind present in `files`.
    ///
    /// Files are grouped by kind, ordered newest-first, and taken until their cumulative size reaches
    /// `ceilingBytes`; the file crossing the ceiling is included so the boundary never drops the run
    /// that spans it. The kept run is returned oldest to newest. `ceilingBytes` is a read bound (pass
    /// the bundle cap); a non-positive ceiling still yields the newest file per kind.
    ///
    /// Deterministic: independent of `files` order, ties break on filename, one `Plan` per kind in `kinds` order.
    public static func mergePlan(files: [(name: String, bytes: Int)],
                                 kinds: [String],
                                 ceilingBytes: Int) -> [Plan] {
        var byKind: [String: [(generation: Int, name: String, bytes: Int)]] = [:]
        for file in files {
            guard let hit = classify(filename: file.name, kinds: kinds) else { continue }
            byKind[hit.kind, default: []].append((hit.generation, file.name, max(0, file.bytes)))
        }
        return kinds.compactMap { kind -> Plan? in
            guard let group = byKind[kind], !group.isEmpty else { return nil }
            // Newest first: generation 0 (live), then 1 (newest retained) upward.
            let newestFirst = group.sorted {
                $0.generation != $1.generation ? $0.generation < $1.generation : $0.name < $1.name
            }
            var kept: [String] = []
            var accumulated = 0
            for file in newestFirst {
                kept.append(file.name)
                accumulated += file.bytes
                if accumulated >= ceilingBytes { break }
            }
            return Plan(entryName: entryName(kind: kind), files: kept.reversed())
        }
    }
}
