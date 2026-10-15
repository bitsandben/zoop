import Foundation

// ConnectionReadout.swift - pure values and line formatters for the Connection & Sync test mode.
//
// ConnectionTrace builds the upfront diagnostic lines the Connection emitters write: the clock-drift
// summary (strap-reported banked-record range vs wall clock, with a future-date flag), the
// firmware-layout line, and the no-cursor / trim sentinel line. ConnectionReadout parses the tagged
// log tail back into the live-readout ids the panel binds (connectionUptime, reconnectCount,
// lastOffloadResult). Pure and side-effect-free (no clock, no I/O); the BLE layer gates calls behind
// TestCentre.active(.connection). No PII: counts, durations and ISO dates only.

public enum ConnectionTrace {
    /// The ` after <n>s` suffix on a `connect down` trace line, or empty when the session start is
    /// unknown (#1020).
    ///
    /// Session length separates causes of a drop at a glance (a bond watchdog fires seconds in, a
    /// keep-alive stall minutes in). An unknown start yields no suffix rather than `after 0.0s`:
    /// "instant drop" and "we do not know" are different diagnoses. Integer half-up quantization makes
    /// exact 50 ms ties deterministic, and rendering digits directly keeps locale out of pasted logs.
    public static func sessionHeldSuffix(millis: Int) -> String {
        guard millis >= 0 else { return "" }
        let tenths = millis / 100 + (millis % 100 >= 50 ? 1 : 0)
        return " after \(tenths / 10).\(tenths % 10)s"
    }


    /// The clock-drift summary line (#767 / #754 cluster): the strap-reported banked-record window
    /// [oldest, newest] against the wall clock, with a FUTURE-DATE flag when the newest record is dated
    /// ahead of wall-now (the tell of a wandering or un-clocked strap).
    ///
    /// All timestamps are unix seconds in the same wall domain, so the future test is a plain
    /// `newest > wallNow + tolerance`. `oldest` is optional (a short range reply gives only the upper
    /// bound). The span is reported in days for the backlog-depth read.
    ///
    /// - Parameter futureToleranceSeconds: slack before flagging FUTURE (strap RTC vs phone skew of a
    ///   minute or two is normal).
    /// - Parameter behindToleranceSeconds: slack before flagging BEHIND (#990). A newest banked record
    ///   naturally trails wall time by hours (unworn strap, backlog), so the default is 48 h; beyond it
    ///   the old line claimed "clockOk" at -363 days, hiding the clock fault.
    public static func clockDriftLine(oldestUnix: Int?,
                                      newestUnix: Int,
                                      wallNowUnix: Int,
                                      futureToleranceSeconds: Int = 120,
                                      behindToleranceSeconds: Int = behindToleranceDefault) -> String {
        let iso = isoDate(newestUnix)
        let aheadSeconds = newestUnix - wallNowUnix
        var line = "clockDrift newest=\(iso) wall=\(isoDate(wallNowUnix)) "
            + "newestVsWall=\(signed(aheadSeconds))s"
        if let oldestUnix {
            let spanDays = max(0, (newestUnix - oldestUnix)) / 86_400
            line += " oldest=\(isoDate(oldestUnix)) spanDays=\(spanDays)"
        }
        line += clockVerdict(aheadSeconds: aheadSeconds, newestUnix: newestUnix,
                             futureToleranceSeconds: futureToleranceSeconds,
                             behindToleranceSeconds: behindToleranceSeconds)
        return line
    }

    // MARK: - Strap-clock verdict (shared by clockDriftLine + UniversalTrace.clockDriftLine, #990/#987)

    /// 1972-01-01 unix. A strap RTC that was never set counts up from its 1970 epoch, so a strap-side
    /// timestamp below this means "the clock never latched" (#77/#91/#987). Public so the readout
    /// warning and the export line share one definition of "epoch-era".
    public static let rtcEpochCeilingUnix = 63_072_000

    /// The default BEHIND drift tolerance (#990): 48 h. A day or two behind is an unworn strap; beyond
    /// that the line must read as a clock warning, never "clockOk".
    public static let behindToleranceDefault = 48 * 3_600

    /// The strap-clock verdict token both clock-drift lines end with, from one function so Connection
    /// and universal lines can't disagree. Most specific first: FUTURE (RTC ahead), RTC-EPOCH (never
    /// set), CLOCK-WARNING (behind by more than the tolerance, #990), else clockOk. A reset clock and a
    /// long-unworn strap look identical from here, so the behind case names both.
    static func clockVerdict(aheadSeconds: Int, newestUnix: Int,
                             futureToleranceSeconds: Int, behindToleranceSeconds: Int) -> String {
        if aheadSeconds > futureToleranceSeconds { return " FUTURE-DATED (strap clock ahead of wall)" }
        if newestUnix < rtcEpochCeilingUnix {
            return " RTC-EPOCH (strap clock reads 1970/71, never set; charge to 100% and reconnect so it latches)"
        }
        if aheadSeconds < -behindToleranceSeconds {
            let days = -aheadSeconds / 86_400
            return " CLOCK-WARNING (newest banked record \(days)d behind wall; strap clock reset or history stale)"
        }
        return " clockOk"
    }

    /// The firmware-layout line for a healthy sync: which historical record layout the strap emits
    /// (v18/v24/v25/v26), surfaced once per distinct version.
    public static func firmwareLine(version: Int, decodable: Bool) -> String {
        "firmware layout=v\(version) \(decodable ? "decodable" : "UNMAPPED (no motion/HR decoded)")"
    }

    /// The trim / no-cursor sentinel line: the strap reported trim=0xFFFFFFFF ("no valid flash cursor"),
    /// so it has no banked history to offload (a clock/charge state, not a decode bug).
    public static func noCursorLine() -> String {
        "offload trim=0xFFFFFFFF noCursor (strap has no banked history to offload)"
    }

    /// Compact ISO-8601 date-time (no fractional seconds) in UTC, so a shared report reads identically
    /// across timezones.
    static func isoDate(_ unix: Int) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    /// Sign-prefixed integer so the newest-vs-wall delta reads as a signed offset.
    static func signed(_ n: Int) -> String { n >= 0 ? "+\(n)" : "\(n)" }
}

/// Pure values for the Connection & Sync live-readout panel. Each parses the `.connection`-tagged
/// log tail so the panel reflects the live link without the BLE layer exposing new published properties.
public enum ConnectionReadout {

    /// Connection uptime for the `connectionUptime` id. The connect emitter writes
    /// "[connection] connect ... uptimeStart=<unix>" when the link comes up and clears it on
    /// disconnect, so the newest connect-or-disconnect line says whether we are up and since when.
    /// `nowUnix` is injected for testability. Returns a short label ("3m 12s" / "not connected").
    public static func uptimeLabel(taggedTail: [String], nowUnix: Int) -> String {
        for line in taggedTail.reversed() {
            if line.contains("connect down") { return "not connected" }
            if let start = intField(line, key: "uptimeStart=") {
                let secs = max(0, nowUnix - start)
                return durationLabel(secs)
            }
        }
        return "not connected"
    }

    /// Reconnect count for the `reconnectCount` id: the highest `reconnect n=<count>` in the tail this
    /// session; 0 when none.
    public static func reconnectCount(taggedTail: [String]) -> Int {
        var maxN = 0
        for line in taggedTail where line.contains("reconnect ") {
            if let n = intField(line, key: "n=") { maxN = max(maxN, n) }
        }
        return maxN
    }

    /// Last offload result for the `lastOffloadResult` id: the newest "offload result=<...>" fragment
    /// (e.g. "complete rows=42 nights=2", "idle-timeout after rows=17205", "stalled (idle timeout,
    /// rows=0)"). The last two are distinct on purpose (#1466): an idle timeout that banked rows is
    /// productive, only rows=0 is a stall. Nil when no offload finished this session.
    public static func lastOffloadResult(taggedTail: [String]) -> String? {
        for line in taggedTail.reversed() {
            if let r = line.range(of: "offload result=") {
                let frag = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !frag.isEmpty { return frag }
            }
        }
        return nil
    }

    /// Rows drained THIS session for the readout row beside the all-time tally (#990): the newest
    /// `sessionRows=<n>` running total, falling back to the final `offload result= ... rows=<n>` once
    /// summarised. Nil when nothing drained.
    public static func sessionRows(taggedTail: [String]) -> Int? {
        for line in taggedTail.reversed() {
            // A finished session's result line wins (it is newest). An "empty (console only)" result has no
            // rows= field and honestly means 0, not an older session's running total.
            if line.contains("offload result=") { return intField(line, key: "rows=") ?? 0 }
            if let n = intField(line, key: "sessionRows=") { return n }
        }
        return nil
    }

    /// Parses the Backfiller's session summary ("Backfill: session persisted N rows (...) across K
    /// night(s).") into its row count, so the log sink can fold each session into the persisted
    /// all-time tally (#990). Emitted unconditionally whenever rows landed, so the counter accrues
    /// whether or not the Connection test mode is on. Nil for any other line.
    public static func drainedRowsFromSummary(_ line: String) -> Int? {
        guard let r = line.range(of: "session persisted ") else { return nil }
        let rest = line[r.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(" rows") else { return nil }
        return Int(digits)
    }

    /// The device-side clock value from the newest "Clock correlated: device=<d> wall=<w>" line (#987),
    /// or nil when none this session. Parsed from the untagged log tail, so the caller passes full log lines.
    public static func clockCorrelatedDevice(logLines: [String]) -> Int? {
        for line in logLines.reversed() where line.contains("Clock correlated:") {
            return intField(line, key: "device=")
        }
        return nil
    }

    /// The "clock latched" readout value (#987/#261). "yes" once either signal lands with a plausible
    /// (post-1972) timestamp: a GET_CLOCK correlation (`deviceClockUnix`, WHOOP4) or a GET_DATA_RANGE
    /// reply's newest banked record (`strapNewestUnix`, the fallback). "no (RTC reads 1970/71)" when the
    /// signal that landed is epoch-era; "no (waiting for the strap clock)" before either replies.
    ///
    /// A WHOOP 5/MG's GET_CLOCK reply rides the puffin notify channel and never reaches the WHOOP4-only
    /// correlation path (see `BLEManager`'s connect-handshake comment), and its records carry absolute
    /// timestamps so it never needs that correlation. Without the data-range fallback the row read
    /// "waiting" forever on every working 5/MG. `rtcWarning` trusts it the same way.
    public static func clockLatchedLabel(deviceClockUnix: Int?, strapNewestUnix: Int? = nil) -> String {
        if let d = deviceClockUnix {
            return d < ConnectionTrace.rtcEpochCeilingUnix ? "no (RTC reads 1970/71)" : "yes"
        }
        // #1823: this branch has not read a clock. It is reached with no correlation (every 5/MG), so the
        // only evidence is how the strap dated its banked records; "RTC reads 1970/71" would claim a
        // reading we never took. Report the evidence we have.
        if let n = strapNewestUnix {
            return n < ConnectionTrace.rtcEpochCeilingUnix ? "no (records dated 1970/71)" : "yes"
        }
        return "no (waiting for the strap clock)"
    }

    /// At or above this charge the "charge it" remedy is already satisfied (#1818).
    public static let rtcAlreadyChargedPct: Double = 95

    /// A plain-words warning when the strap RTC reads epoch-era (~1970/71) from either signal (the
    /// correlated device clock or the newest banked-record timestamp) (#987). Nil when both look sane
    /// or neither was seen: never a fabricated fault. One string, shown verbatim on the Devices / Test
    /// Centre readout, naming the consequence and the fix.
    ///
    /// The remedy is battery-dependent (#1818): a flat battery resets the RTC, so on a low strap
    /// "charge it" is real advice; on an already-charged strap it is not. The charged branch states only
    /// what holds for every strap (charging again won't change it) and asks for a log. It must NOT claim
    /// Zoop re-sends the clock on every connect: true on WHOOP4 (`runConnectHandshake` calls SET_CLOCK
    /// unconditionally, #120), false on a 5/MG, where the clock write is gated behind `didBond` and an
    /// unbondable 5/MG (#1635) is never clocked. `batteryPct` nil keeps the charge advice (withdrawn
    /// only on evidence). Callers MUST pass a reading from the current link (iOS:
    /// `batterySamples.last?.soc`, cleared on disconnect); a stale 100% would suppress the advice for a
    /// strap that ran flat and reset its RTC.
    public static func rtcWarning(deviceClockUnix: Int?, strapNewestUnix: Int?,
                                  batteryPct: Double? = nil) -> String? {
        let ceiling = ConnectionTrace.rtcEpochCeilingUnix
        let clockBad = deviceClockUnix.map { $0 > 0 && $0 < ceiling } ?? false
        let newestBad = strapNewestUnix.map { $0 > 0 && $0 < ceiling } ?? false
        guard clockBad || newestBad else { return nil }
        let lead = "Strap clock reads 1970/71 (never set since its last reset), so it is not banking history. "
        if let batteryPct, batteryPct >= rtcAlreadyChargedPct {
            return lead
                + "The strap is already charged, so charging again will not change this. Export a strap "
                + "log from Test Centre so the clock exchange can be read."
        }
        return lead + "Charge the strap to 100% and reconnect so the clock latches."
    }

    /// One-line account of a finished BLE link, logged on every disconnect (#1809), answering "did the
    /// strap send anything?" from inbound-frame counts and the real `CBError` code.
    ///
    /// `armed` matters because the #80 marginal-radio fallback only counts a drop when the R10/R11 burst
    /// was armed; `armed=no` says the detector cannot trip for this link.
    ///
    /// `rssiDbm` tests the leading suspect for a supervision-timeout drop (range). Apple never read link
    /// RSSI before: `discoveredWhoops` carries a scan-time reading from before the connection existed.
    /// The reading is printed with its age, because it is only evidence if taken near the drop. The
    /// caller MUST clear its stash on teardown (like `linkUpSince`) or the epitaph invents evidence;
    /// `never read on this link` is the honest answer. RSSI is not clamped (it is negative by nature);
    /// implausible values are the caller's to reject at the stash.
    ///
    /// #2397: `rssiReads`, `rssiWorstDbm` and `rssiSumDbm` describe every reading the link took, since
    /// a last value alone cannot separate a marginal link from one that walked out of range. The mean is
    /// computed here from a sum and count so both platforms divide the same way.
    ///
    /// Milliseconds are printed raw (no float formatting); `rssiAgeMillis` shares `upMillis`' units.
    public static func linkEpitaph(upMillis: Int, inboundFrames: Int, inboundBytes: Int,
                                   cmdChannelFrames: Int, realtimeArmed: Bool, ended: String,
                                   rssiDbm: Int?, rssiAgeMillis: Int?,
                                   rssiReads: Int = 0, rssiWorstDbm: Int? = nil,
                                   rssiSumDbm: Int = 0) -> String {
        let armed = realtimeArmed ? "yes" : "no"
        // #2397: the shape of the link's signal. Two readings is the floor: with one, worst and mean are
        // the value already printed.
        let shape: String
        if rssiReads >= 2, let rssiWorstDbm {
            // Integer division truncating toward zero on both platforms, so logs can't round apart; one dB of
            // truncation doesn't change what a shape of a handful of readings says.
            shape = "; n=\(rssiReads) worst=\(rssiWorstDbm)dBm mean=\(rssiSumDbm / rssiReads)dBm"
        } else {
            shape = ""
        }
        let signal: String
        if let rssiDbm {
            if let rssiAgeMillis {
                signal = "\(rssiDbm)dBm (read \(max(0, rssiAgeMillis))ms before the drop\(shape))"
            } else {
                signal = "\(rssiDbm)dBm (age unknown\(shape))"
            }
        } else {
            signal = "never read on this link"
        }
        var line = "Link epitaph: up \(max(0, upMillis))ms, inbound \(max(0, inboundFrames)) frames / "
            + "\(max(0, inboundBytes)) bytes (cmd-channel \(max(0, cmdChannelFrames))), "
            + "realtime armed=\(armed), signal=\(signal), ended=\(ended)"
        if inboundFrames <= 0 {
            line += " - the strap sent NOTHING on this link"
        }
        return line
    }

    /// What a finished link actually stored, split by PATH (#1635).
    ///
    /// The epitaph counts frames, which misleads for a strap talking over only part of its surface: an
    /// unbonded 5/MG streams HR and R-R all night while nothing bond-gated lands. The split is by path,
    /// not stream: the realtime decoder produces only hr, rr, events and battery; gravity, respiratory,
    /// skin temperature, SpO2 and steps arrive solely through the historical decoder behind the offload.
    /// A live-only tally would print "nothing banked live for: gravity, resp, ..." on every link.
    ///
    /// The offload is where the bond shows: an unbonded strap defers backfill entirely, so `offload none`
    /// is the signal. Battery is absent on purpose (standard 0x2A19 profile, banks regardless of bond).
    /// `offloadSteps` is optional so a platform that can't measure a stream omits it rather than
    /// reporting a misleading zero. Counts are rows ACCEPTED. Pure, total and clamped.
    public static func linkBankedSummary(liveHr: Int, liveRr: Int, offloadChunks: Int,
                                         offloadHr: Int, offloadRr: Int, offloadGravity: Int,
                                         offloadResp: Int, offloadSkinTemp: Int, offloadSpo2: Int,
                                         offloadSteps: Int?) -> String {
        let live = "live hr=\(max(0, liveHr)) rr=\(max(0, liveRr))"
        var raw: [(String, Int)] = [
            ("hr", offloadHr), ("rr", offloadRr), ("gravity", offloadGravity), ("resp", offloadResp),
            ("skinTemp", offloadSkinTemp), ("spo2", offloadSpo2),
        ]
        if let offloadSteps { raw.append(("steps", offloadSteps)) }
        let offload = raw.map { ($0.0, max(0, $0.1)) }
        let total = offload.reduce(0) { $0 + $1.1 }
        // Three states, reported as facts, not verdicts. "No chunks" alone isn't a fault (a short or
        // command-only link never reaches backfill; the epitaph supplies the uptime to weigh it).
        // "Never ran" and "ran with nothing new" still differ: rows count as ACCEPTED, so a reconnect
        // re-offloading stored records banks zero while the strap handed its history over. Only the first
        // speaks to the bond.
        if (max(0, offloadChunks)) == 0 {
            return "banked this link: \(live) | offload none"
        }
        if total == 0 {
            return "banked this link: \(live) | offload ran \(max(0, offloadChunks)) chunk(s), no new rows"
        }
        let body = offload.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        let empty = offload.filter { $0.1 == 0 }.map { $0.0 }
        if empty.isEmpty { return "banked this link: \(live) | offload \(body)" }
        return "banked this link: \(live) | offload \(body)"
            + " - nothing banked from the offload for: \(empty.joined(separator: ", "))"
    }

    /// Freshness label for the "last frame" row: how long ago the newest strap frame was routed
    /// ("12s ago"), or "no frames yet" (#987). `nowUnix` is injected for testability.
    public static func lastFrameLabel(lastFrameUnix: Int?, nowUnix: Int) -> String {
        guard let t = lastFrameUnix else { return "no frames yet" }
        return durationLabel(max(0, nowUnix - t)) + " ago"
    }

    /// Parses a `key=<int>` field (value runs to the next space); nil when absent or non-numeric.
    static func intField(_ line: String, key: String) -> Int? {
        guard let r = line.range(of: key) else { return nil }
        let token = line[r.upperBound...].prefix { $0 != " " }
        return Int(token)
    }

    /// Short "Xm Ys" / "Xs" / "Xh Ym" duration label for the uptime readout.
    static func durationLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}
