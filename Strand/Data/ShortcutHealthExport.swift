import Foundation
import WhoopStore
import WhoopProtocol
import StrandAnalytics

/// Apple-Health-free export for sideloaded iOS installs, which cannot carry the HealthKit entitlement.
/// Writes a plain-text file in Documents (exposed to Files/Shortcuts) that a Siri Shortcut logs into
/// Apple Health. One line per 15-minute window, `HR,HRV,Steps,yyyy-MM-dd HH:mm`, en_US_POSIX, LOCAL
/// time, empty fields keep their commas, no header.
///
/// Reads ONLY the strap source (`repo.deviceId`): never `apple-health` (a Shortcut-logged value must not
/// round-trip back in) and never the computed source.
enum ShortcutHealthExport {

    /// Opt-in gate, default off.
    static let enabledKey = "zoop.shortcutSync.enabled"
    /// Exclusive end of the last successfully written coverage, unix seconds. Advances only after a
    /// successful write, so a failed export retries the same span.
    static let watermarkKey = "zoop.shortcutSync.lastExportTs"
    static let fileName = "noop_sync.txt"
    /// Aggregation window: 15 minutes, epoch-aligned like `hrBuckets(900)`.
    static let windowSeconds = 900
    /// Catch-up bound: never reach back further than 7 days.
    static let lookbackSeconds = 7 * 86_400
    /// Reboot/reset guard for the cumulative u16 step counter, same cap as the daily-steps math (a reset
    /// is indistinguishable from a wrap; a huge corrected delta is a reset, not steps).
    static let maxStepDelta = 30_000
    /// Row cap for the RR/step reads; 7 days of ~1 Hz RR is ~600k rows, so a real window is never truncated.
    static let readLimit = 2_000_000

    enum Outcome: Equatable {
        case written(lines: Int)
        case nothingNew
        case failure(String)
    }

    /// One 15-minute export window. Emitted iff at least one of the three values is set.
    struct Window: Equatable {
        let start: Int          // unix seconds, windowSeconds-aligned
        var hr: Int? = nil      // mean bpm over the window, rounded
        var hrvMs: Double? = nil // RMSSD over the window's RR intervals (1 decimal at render)
        var steps: Int? = nil   // wrap-corrected positive-delta sum
    }

    // MARK: - Entry points

    /// Background-transition hook. No-op until the user opts in.
    @MainActor
    static func writeIfEnabled(repo: Repository) async {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
        _ = await writeNow(repo: repo)
    }

    @MainActor
    @discardableResult
    static func writeNow(repo: Repository) async -> Outcome {
        guard let store = await repo.storeHandle() else {
            return .failure("Couldn't open the local store.")
        }
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return .failure("No Documents directory.")
        }
        return await export(source: store, deviceId: repo.deviceId, now: Date(),
                            defaults: .standard, directory: docs, timeZone: .current)
    }

    /// Injectable core (store reads, clock, defaults, destination and zone as parameters) so the watermark and file semantics are unit-testable.
    @discardableResult
    static func export(source: ShortcutExportReads, deviceId: String, now: Date,
                       defaults: UserDefaults, directory: URL, timeZone: TimeZone) async -> Outcome {
        let nowTs = Int(now.timeIntervalSince1970)
        let span = coverageSpan(nowTs: nowTs, watermark: defaults.integer(forKey: watermarkKey))
        guard span.from < span.end else {
            // Nothing new: TRUNCATE rather than leave old rows. The Shortcut has no dedup and fires on every app
            // close, so a stale file would be re-imported every run (#167). Rows the Shortcut never read before
            // the next truncate are skipped by design; resetWatermark() re-emits the window.
            try? Data().write(to: directory.appendingPathComponent(fileName), options: .atomic)
            return .nothingNew
        }
        do {
            let hr = try await source.hrBuckets(deviceId: deviceId, from: span.from,
                                                to: span.end - 1, bucketSeconds: windowSeconds)
            let rr = try await source.rrIntervals(deviceId: deviceId, from: span.from,
                                                  to: span.end - 1, limit: readLimit)
            let steps = try await source.stepSamples(deviceId: deviceId, from: span.from,
                                                     to: span.end - 1, limit: readLimit)
            let windows = aggregate(hr: hr, rr: rr, steps: steps, end: span.end)
            // Full-file replace even with 0 windows: stale lines would be double-logged by the Shortcut.
            try Data(render(windows, timeZone: timeZone).utf8)
                .write(to: directory.appendingPathComponent(fileName), options: .atomic)
            defaults.set(span.end, forKey: watermarkKey)   // only after the write landed
            return .written(lines: windows.count)
        } catch {
            return .failure("Shortcut export failed: \(error.localizedDescription)")
        }
    }

    /// Drops the watermark so the next export re-emits the full 7-day window.
    static func resetWatermark(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: watermarkKey)
    }

    // MARK: - Pure logic

    /// Coverage `[from, end)`: `from` is the watermark clamped to the 7-day lookback, `end` the start of
    /// the still-open window. The open window is excluded; exporting it would freeze a partial value.
    static func coverageSpan(nowTs: Int, watermark: Int) -> (from: Int, end: Int) {
        ((max(watermark, nowTs - lookbackSeconds)), (nowTs / windowSeconds) * windowSeconds)
    }

    /// Folds the three streams into window-aligned windows below `end`, ascending; only windows holding a value are returned.
    static func aggregate(hr: [HRBucket], rr: [RRInterval], steps: [StepSample], end: Int) -> [Window] {
        var byStart: [Int: Window] = [:]
        func update(_ start: Int, _ mutate: (inout Window) -> Void) {
            var w = byStart[start] ?? Window(start: start)
            mutate(&w)
            byStart[start] = w
        }
        func windowStart(_ ts: Int) -> Int { (ts / windowSeconds) * windowSeconds }

        // HR: hrBuckets(900) already keys by window start.
        for b in hr where b.ts < end {
            update(b.ts) { $0.hr = Int(b.bpm.rounded()) }
        }

        // HRV: RMSSD per window via the shared analyzer; nil (< 20 clean beats) leaves the field empty.
        var rrByWindow: [Int: [Double]] = [:]
        for s in rr.sortedByTsStable() where s.ts < end {
            rrByWindow[windowStart(s.ts), default: []].append(Double(s.rrMs))
        }
        for (start, values) in rrByWindow {
            if let rmssd = HRVAnalyzer.analyze(rawRR: values).rmssd {
                update(start) { $0.hrvMs = rmssd }
            }
        }

        // Steps: cumulative-u16 delta math. Negative delta = wrap (+65536); corrected deltas above
        // maxStepDelta are firmware-reset artifacts and dropped. Each delta lands in the window of the
        // LATER sample.
        let sorted = steps.sorted { $0.ts < $1.ts }
        if sorted.count >= 2 {
            for i in 1..<sorted.count {
                var delta = sorted[i].counter - sorted[i - 1].counter
                if delta < 0 { delta += 65_536 }  // u16 wraparound
                guard delta >= 1 && delta <= maxStepDelta else { continue }  // drop resets
                let start = windowStart(sorted[i].ts)
                guard start < end else { continue }
                update(start) { $0.steps = ($0.steps ?? 0) + delta }
            }
        }

        return byStart.values.sorted { $0.start < $1.start }
    }

    /// Empty fields keep their commas; HRV to 1 decimal; timestamp is the window START in the given zone.
    static func line(_ w: Window, timeZone: TimeZone) -> String {
        let hr = w.hr.map(String.init) ?? ""
        let hrv = w.hrvMs.map { String(format: "%.1f", $0) } ?? ""
        let steps = w.steps.map(String.init) ?? ""
        return "\(hr),\(hrv),\(steps),\(timestamp(w.start, timeZone: timeZone))"
    }

    /// No header and no trailing newline (it would give the Shortcut an empty last row).
    static func render(_ windows: [Window], timeZone: TimeZone) -> String {
        windows.map { line($0, timeZone: timeZone) }.joined(separator: "\n")
    }

    // en_US_POSIX per the project's date contract; zone set per call. Shared instance, one task at a time.
    private static let lineFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func timestamp(_ ts: Int, timeZone: TimeZone) -> String {
        lineFormatter.timeZone = timeZone
        return lineFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}

/// The three store reads the export needs, a seam for testing without a live DB.
protocol ShortcutExportReads {
    func hrBuckets(deviceId: String, from: Int, to: Int, bucketSeconds: Int) async throws -> [HRBucket]
    func rrIntervals(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [RRInterval]
    func stepSamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [StepSample]
}

extension WhoopStore: ShortcutExportReads {}
