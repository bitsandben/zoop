import Foundation
import StrandAnalytics
import WhoopStore

/// Assembles the Test Centre export bundle (report.txt, meta.json, raw-capture, last-crash, Oura
/// sidecars), redacts every file, applies the size cap and hands the entries to
/// FileExport.exportBundle. Redaction stays the only scrub point: `LiveState.redactPii` is re-run
/// over every entry's text here and meta.redaction = "v2" stamps that it ran.
enum TestBundleAssembler {

    /// The redaction stamp written into meta.json.
    static let redactionVersion = "v2"

    /// The bundle's hard byte cap (under GitHub's 25 MB attachment limit), shared by `capEntries` and
    /// `ouraDiagnosticEntries` so the read ceiling can't drift above the budget.
    static let defaultCapBytes = 20 * 1024 * 1024

    /// The Oura Diagnostics-dir sidecar kinds the bundle attaches; the single source for
    /// `normalizedOuraEntryName`/`ouraDiagnosticEntries`/`trimmableNames`/`ouraSidecarNames`. A new dump
    /// writer (`Strand/BLE/Oura*Dump.swift`) needs exactly one line added here.
    static let ouraSidecarKinds: [String] = ["raw", "ibihr", "activity", "cva-ppg", "motion", "real-steps"]

    /// Bundle files that may be trimmed to fit the cap (newest tail kept): the WHOOP frame capture and
    /// the Oura Tier-B JSONL sidecars. Everything else is kept whole and its bytes reserved first.
    /// Normalized entry names (ring id dropped).
    static let trimmableNames: Set<String> = Set(["raw-capture.jsonl"] + ouraSidecarKinds.map { "oura-\($0).jsonl" })

    /// Oura sidecars carry the ring id in a `"deviceId"` JSON field. The whole-bundle UUID scrub masks
    /// only canonical dashed UUIDs, so for these sidecars the `deviceId` VALUE is also masked by field
    /// name (any id shape, and it can't touch the raw `hex` field). Normalized names.
    static let ouraSidecarNames: Set<String> = Set(ouraSidecarKinds.map { "oura-\($0).jsonl" })

    /// `oura-raw.jsonl` is the one sidecar whose payload is only hex; `LiveState.redactHexDump`'s byte-run
    /// heuristic must skip it (the other sidecars encode decoded numeric fields).
    private static let rawHexSidecarNames: Set<String> = ["oura-raw.jsonl"]

    /// Re-runs the redaction sink over every entry: text is decoded as UTF-8, scrubbed with
    /// `LiveState.redactPii` and re-encoded; a non-UTF-8 entry passes through untouched.
    ///
    /// `oura-raw.jsonl` skips the `redactPii` sweep (see `rawHexSidecarNames`): its `hex` field is the
    /// ring's undecoded TLV bytes, and `redactHexDump` would silently replace ordinary sensor bytes with
    /// non-hex `•` placeholders. The ring serial is filtered at the source by
    /// `OuraLiveSource.rawDumpBytes`; the `deviceId` field mask below still runs unconditionally.
    static func redactEntries(_ entries: [FileExport.BundleEntry]) -> [FileExport.BundleEntry] {
        entries.map { entry in
            guard let text = String(data: entry.data, encoding: .utf8) else { return entry }
            var scrubbed = rawHexSidecarNames.contains(entry.name) ? text : LiveState.redactPii(text)
            // Field-aware deviceId mask for the Oura sidecars (see `ouraSidecarNames`); runs after redactPii,
            // is key-anchored so it never touches `hex`, and `[^"]*` stops at the closing quote.
            if ouraSidecarNames.contains(entry.name) {
                scrubbed = scrubbed.replacingOccurrences(
                    of: "(\"deviceId\"\\s*:\\s*\")[^\"]*(\")",
                    with: "$1<device>$2", options: .regularExpression)
            }
            return FileExport.BundleEntry(name: entry.name, data: Data(scrubbed.utf8))
        }
    }

    /// Hard-caps the bundle at `capBytes` (20 MB default). Non-trimmable files are reserved whole, the
    /// remaining budget is shared across the `trimmableNames` streams, and each keeps its most recent
    /// tail (trimmed from the front). Returns the capped entries and whether anything was truncated
    /// (meta.truncated). Allocation is max-min fair (see `fairAllowances`); with one trimmable file its
    /// share is the whole remainder.
    static func capEntries(_ entries: [FileExport.BundleEntry],
                           capBytes: Int = defaultCapBytes) -> (entries: [FileExport.BundleEntry], truncated: Bool) {
        let total = entries.reduce(0) { $0 + $1.data.count }
        guard total > capBytes else { return (entries, false) }
        // Reserve the non-trimmable files, then share the remainder across the trimmable ones.
        let nonTrimmable = entries.filter { !trimmableNames.contains($0.name) }.reduce(0) { $0 + $1.data.count }
        let budget = max(0, capBytes - nonTrimmable)
        let allowance = fairAllowances(
            sizes: entries.filter { trimmableNames.contains($0.name) }.map { ($0.name, $0.data.count) },
            budget: budget)
        var truncated = false
        let capped = entries.map { entry -> FileExport.BundleEntry in
            guard trimmableNames.contains(entry.name) else { return entry }
            let share = allowance[entry.name] ?? 0
            guard entry.data.count > share else { return entry }
            truncated = true
            // Keep the tail: the last `share` bytes, snapped forward to the next full JSONL line (a raw
            // byte-count tail can land mid-record and corrupt the first line).
            return FileExport.BundleEntry(name: entry.name,
                                          data: Self.trimToLineBoundary(entry.data.suffix(share)))
        }
        return (capped, truncated)
    }

    /// Splits `budget` bytes across the named streams max-min fairly: smallest first, each offered an
    /// equal share of what remains; a stream under its share takes only what it needs and the surplus
    /// rolls forward. The integer floor keeps the sum within `budget`. Pure; input order is irrelevant.
    ///
    /// Not proportional-to-size: that hands the budget to the bulkiest stream, which is least diagnostic.
    /// On a real export it gave a per-sample `oura-spo2.jsonl` 53.9% and starved `oura-raw.jsonl`
    /// (the undecoded wire bytes, the one file a protocol fact can be re-derived from) to 1.9%.
    static func fairAllowances(sizes: [(name: String, bytes: Int)], budget: Int) -> [String: Int] {
        // Smallest-first, name-tiebroken for determinism.
        let ordered = sizes.sorted { $0.bytes != $1.bytes ? $0.bytes < $1.bytes : $0.name < $1.name }
        var allowance: [String: Int] = [:]
        var left = max(0, budget)
        var unserved = ordered.count
        for stream in ordered {
            let share = unserved > 0 ? left / unserved : 0
            let give = min(max(0, stream.bytes), share)
            allowance[stream.name] = give
            left -= give
            unserved -= 1
        }
        return allowance
    }

    /// Drops bytes up to and including the first newline so a byte-count tail never starts mid-line;
    /// unchanged when there is no newline. Pure.
    static func trimToLineBoundary(_ data: Data) -> Data {
        guard let newline = data.firstIndex(of: 0x0A) else { return data }
        let start = data.index(after: newline)
        return data.subdata(in: start..<data.endIndex)
    }

    // MARK: - assemble

    /// The build channel string for meta.json (sideload / App Store / fixed per flavour); never fabricated.
    private static func buildProvenance() -> TestBundleMeta.Build {
        #if os(iOS)
        let sideloaded = IOSDiagnostics.capture().isSideloaded ?? true
        return TestBundleMeta.Build(channel: sideloaded ? "sideload" : "App Store", signed: !sideloaded)
        #elseif os(macOS)
        // The macOS build ships unsigned and un-notarized.
        return TestBundleMeta.Build(channel: "GitHub", signed: false)
        #else
        return TestBundleMeta.Build(channel: "GitHub", signed: false)
        #endif
    }

    /// Gathers the report files for `profile`, redacts every file, caps the bundle, then builds,
    /// redacts and appends meta.json. Returns the final entries ready for FileExport.exportBundle.
    /// `storage` / `strapModel` are real probes gathered async by TestCentreReport (they come off the
    /// store actor); nil means the probe could not run and meta carries a zeroed block, never a made-up figure.
    @MainActor
    static func assemble(profile: TestDomain, live: LiveState,
                         storage: TestBundleMeta.Storage? = nil,
                         strapModel: String? = nil) -> [FileExport.BundleEntry] {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        #if os(iOS)
        let platform = "iOS"
        #else
        let platform = "macOS"
        #endif

        // 0. Universal clock-drift line, built from the strap-range snapshot BLEManager banked. It rides
        //    every export and is appended before the completeness scan so the guard reads it. No-op when no
        //    range was seen this session.
        let baseReport = live.exportableLogText()
        // Universal lines are appended in a fixed order so two reports from one strap diff cleanly; an
        // absent line is omitted, not stubbed. The ring-epoch line derives from the same sidecar entries
        // collected below, so it reads nothing new off disk.
        let ouraDiagnostics = ouraDiagnosticEntries()
        let universalLines = [
            universalClockDriftLine(range: live.strapRange),
            universalRRTransportLine(transport: live.rrTransport),
            universalOuraRingEpochLine(entries: ouraDiagnostics),
        ].compactMap { $0 }
        let reportText = universalLines.isEmpty
            ? baseReport
            : baseReport + universalLines.map { "\n[universal] " + $0 }.joined()

        // 1. report.txt: the exportable strap log plus the universal lines; re-scrubbed by redactEntries below.
        let reportEntry = FileExport.BundleEntry(name: "report.txt", data: Data(reportText.utf8))

        // 1b. Display profile (or any mode with includesScreenshot): screenshot.png. It is binary, so it
        //     stays OUT of redactEntries (redaction scrubs text, never pixels) but is covered by the
        //     review-before-share gate.
        let wantsShot = profile == .display
            || (TestModeRegistry.mode(profile)?.includesScreenshot ?? false)
        let shot: FileExport.BundleEntry? = wantsShot
            ? DisplayScreenshot.capturePNG().map { FileExport.BundleEntry(name: DisplayScreenshot.bundleName, data: $0) }
            : nil

        // 1c. raw-capture.jsonl, read from disk when present. It is text whose console strings can carry a
        //     serial, so it IS redacted below.
        let rawCapture: FileExport.BundleEntry? = live.puffinCaptureURL
            .flatMap { fileEntry(at: $0, name: "raw-capture.jsonl") }

        // 1d. last-crash.txt when present on disk (normally absent; no crash producer yet). Text, so redacted.
        let crash: FileExport.BundleEntry? = crashLogURL()
            .flatMap { fileEntry(at: $0, name: "last-crash.txt") }

        // 1e. Oura ring Tier-B sidecars from <App Support>/OpenWhoop/Diagnostics, attached when present
        //     (file presence is the gate; no ring means nothing attached). Text whose only PII is the ring
        //     UUID, masked below; entry names are normalized (redaction never touches names). Trimmed to
        //     the cap via `trimmableNames`.

        // 2. Redact the text files, then cap. The screenshot counts against the cap but is not redacted, so
        //    a large PNG shrinks the trimmable tails rather than breaching the cap.
        let textEntries = [reportEntry] + (rawCapture.map { [$0] } ?? []) + (crash.map { [$0] } ?? []) + ouraDiagnostics
        let redacted = redactEntries(textEntries)
        let (capped, truncated) = capEntries(redacted + (shot.map { [$0] } ?? []))
        var entries = capped

        // 2b. Report-completeness guard: for each domain active during this capture, scan the redacted
        //     report.txt for its killer-trace tokens and produce OK / INCOMPLETE, naming which capture
        //     failed. `.universal` is graded whenever any mode was active. Re-read from `capped` so the scan
        //     and shipped text can't diverge.
        let redactedReport = capped.first { $0.name == "report.txt" }
            .flatMap { String(data: $0.data, encoding: .utf8) } ?? reportText
        let active = activeDomains()
        let checks = CaptureCompleteness.evaluate(activeDomains: active, reportText: redactedReport)
        let section = CaptureCompleteness.reportSection(checks)
        if !section.isEmpty {
            // Append the Capture-check section and re-redact to keep the single-scrub-point invariant.
            let appended = redactedReport + "\n" + section
            entries = entries.map { e in
                e.name == "report.txt"
                    ? redactEntries([FileExport.BundleEntry(name: "report.txt", data: Data(appended.utf8))])[0]
                    : e
            }
        }

        // 3. meta.json: questionnaire answers saved for this profile, ISO8601 profileStartedAt, and the
        //    caller's real storage/strapModel probes (nil falls back to zeros meaning "unreadable").
        //    capture_check carries the same verdicts as the report section.
        let started = TestCentre.startedAt(profile).map { ISO8601DateFormatter().string(from: $0) }
        let meta = TestBundleMeta(
            schema: 1,
            appVersion: version,
            platform: platform,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            strapModel: strapModel,
            source: ["Live Bluetooth"],
            testProfile: profile.id,
            profileStartedAt: started,
            questionnaire: TestCentre.answers(profile),
            build: buildProvenance(),
            storage: storage ?? TestBundleMeta.Storage(dbBytes: 0, rows: [:], rawCaptureBytes: 0, rowBytes: [:]),
            redaction: redactionVersion,
            truncated: truncated,
            captureCheck: checks)

        // meta.json has no PII shapes, but routing it through the same sink keeps one scrub point.
        entries += redactEntries([FileExport.BundleEntry(name: "meta.json", data: meta.encoded())])
        return entries
    }

    // MARK: - Helpers

    /// One `[universal]` line when the Oura sidecars disagree about where the ring's clock started, or
    /// nil when they agree (the common case). The ticks x10 defect (#2239) filed whole sessions in the
    /// past and the store keeps no ring-time, so the decoded sidecars' epoch (`utc - ringTs/10`)
    /// separates a mis-anchored session from an honest one. Derived from the entries the bundle already
    /// collected. Describes, does not classify: a genuine ring restart also starts a new epoch.
    static func universalOuraRingEpochLine(entries: [FileExport.BundleEntry]) -> String? {
        // `oura-raw.jsonl` is skipped by name: undecoded bytes with no `ringTs`, and routinely the largest
        // sidecar, so scanning it is wasted work. Other kinds stay eligible.
        let rows = entries
            .filter { $0.name.hasPrefix("oura-") && $0.name != "oura-raw.jsonl" }
            .flatMap { ouraSidecarRows(String(decoding: $0.data, as: UTF8.self)) }
        guard !rows.isEmpty else { return nil }
        return OuraRingEpochScan.summaryLine(OuraRingEpochScan.cluster(rows))
    }

    /// Pulls `(ringTs, utc)` out of a decoded Oura sidecar's JSONL text. App-layer (not beside
    /// `OuraRingEpochScan` in WhoopStore, where the epoch math lives) because reading these files isn't
    /// shared work. Scans for the two fields instead of decoding JSON: a truncated or unknown-schema
    /// line (a sidecar's last line is often a partial write) is skipped, not fatal.
    static func ouraSidecarRows(_ text: String) -> [(ringTs: UInt32, utc: Int)] {
        var out: [(ringTs: UInt32, utc: Int)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let rt = ouraSidecarInt("ringTs", in: line), let utc = ouraSidecarInt("utc", in: line),
                  rt > 0, rt <= Int(UInt32.max) else { continue }
            out.append((UInt32(rt), utc))
        }
        return out
    }

    /// The integer value of `"name":<digits>` in `line`, or nil; matches the quoted key so "utc" doesn't read "utcOffset".
    static func ouraSidecarInt(_ name: String, in line: Substring) -> Int? {
        guard let keyRange = line.range(of: "\"\(name)\":") else { return nil }
        var digits = ""
        var i = keyRange.upperBound
        if i < line.endIndex, line[i] == "-" { digits.append("-"); i = line.index(after: i) }
        while i < line.endIndex, line[i].isNumber {
            digits.append(line[i])
            i = line.index(after: i)
        }
        return Int(digits)
    }

    /// The universal R-R transport line: what the device banked versus what its unit policy can score.
    /// nil when nothing is resolved this session or the device isn't governed. The judgement is
    /// `UniversalTrace.rrTransportLine`.
    static func universalRRTransportLine(transport: LiveState.RRTransport?) -> String? {
        guard let transport else { return nil }
        return UniversalTrace.rrTransportLine(strictWhoop5: transport.strictWhoop5,
                                              firstRecordedUnix: transport.firstRecordedUnix,
                                              firstScorableUnix: transport.firstScorableUnix)
    }

    /// The universal clock-drift line from the strap-range snapshot, or nil when no range was seen or
    /// only a firmware-only snapshot exists (newest == 0). Delegates the format to `UniversalTrace`;
    /// `now` is injectable for tests.
    static func universalClockDriftLine(range: LiveState.StrapRange?,
                                        now: Int = Int(Date().timeIntervalSince1970)) -> String? {
        guard let range, range.newestUnix > 0 else { return nil }
        return UniversalTrace.clockDriftLine(newestUnix: range.newestUnix, wallNowUnix: now,
                                             oldestUnix: range.oldestUnix, firmwareLayout: range.firmwareLayout)
    }

    /// Domains active during this capture, plus `.universal` whenever any mode was on. Reads the same
    /// `TestCentre.active` gate the emitters check.
    static func activeDomains() -> Set<TestDomain> {
        var s = Set(TestDomain.allCases.filter { $0 != .universal && TestCentre.active($0) })
        if !s.isEmpty { s.insert(.universal) }
        return s
    }

    /// Reads a file into a redactable bundle entry (raw bytes; the caller redacts), or nil if absent or unreadable.
    static func fileEntry(at url: URL, name: String) -> FileExport.BundleEntry? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return FileExport.BundleEntry(name: name, data: data)
    }

    /// The `OpenWhoop/Diagnostics` directory the Oura dumps write into (Application Support), matching
    /// the dumps' own resolver. Read-only: never creates it, so nil when nothing was captured.
    static func ouraDiagnosticsDir() -> URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: false) else { return nil }
        return base.appendingPathComponent("OpenWhoop/Diagnostics", isDirectory: true)
    }

    /// Maps a diagnostics filename to a normalized bundle entry name that drops the ring id
    /// (`oura-<type>-<ringId>.jsonl` to `oura-<type>.jsonl`), or nil if it isn't an Oura sidecar in
    /// `ouraSidecarKinds`. A rolled generation (`.jsonl.<n>`) maps to the same name, since
    /// `ouraDiagnosticEntries` merges generations behind it. Thin wrapper over
    /// `WhoopStore.OuraSidecarGenerations`, where the rule is unit-tested under `swift test`.
    static func normalizedOuraEntryName(forFile filename: String) -> String? {
        guard let hit = OuraSidecarGenerations.classify(filename: filename, kinds: ouraSidecarKinds)
        else { return nil }
        return OuraSidecarGenerations.entryName(kind: hit.kind)
    }

    /// Gathers the Oura Tier-B JSONL sidecars as bundle entries (normalized names, raw bytes; the caller
    /// redacts and caps). Enumerates the Diagnostics dir, so it needs no active-ring id.
    ///
    /// Files sharing an entry name (live session, rolled generations, rarely two rings) are concatenated
    /// oldest to newest so the cap's keep-the-tail trim decides what ships (`OuraSidecarGenerations.mergePlan`).
    /// This replaced largest-wins, the wrong criterion: the wake drain flushes the whole night at once,
    /// so the biggest generation is not necessarily the one holding the night.
    ///
    /// Reads are bounded by `capBytes`. `directory` is injectable for tests.
    static func ouraDiagnosticEntries(capBytes: Int = defaultCapBytes,
                                      directory: URL? = nil) -> [FileExport.BundleEntry] {
        guard let dir = directory ?? ouraDiagnosticsDir(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey])
        else { return [] }
        let sizes: [(name: String, bytes: Int)] = files.map { url in
            // Size from the directory entry, so planning never reads a file it won't ship.
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return (url.lastPathComponent, bytes)
        }
        let plans = OuraSidecarGenerations.mergePlan(files: sizes, kinds: ouraSidecarKinds,
                                                     ceilingBytes: capBytes)
        return plans.compactMap { plan in
            var merged = Data()
            for filename in plan.files {
                guard let part = try? Data(contentsOf: dir.appendingPathComponent(filename)),
                      !part.isEmpty else { continue }
                // Newline-delimit generations so a missing final newline can't splice two records together.
                if let last = merged.last, last != 0x0A { merged.append(0x0A) }
                merged.append(part)
            }
            guard !merged.isEmpty else { return nil }
            return FileExport.BundleEntry(name: plan.entryName, data: merged)
        }
    }

    /// Where a crash report would live (app caches dir, never iCloud-synced); normally absent until a crash handler writes here.
    static func crashLogURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("noop-last-crash.txt")
    }
}
