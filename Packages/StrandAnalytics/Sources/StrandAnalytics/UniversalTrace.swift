import Foundation

// UniversalTrace: the lines that ride EVERY Test Centre export, not only in Connection mode, so a Sleep or
// Battery report from a clock-broken strap still carries the clock-drift and firmware-layout picture
// (RTC cluster #531 / #767 / #804 / #812). Pure: no clock read of its own, no I/O, no PII (ISO dates,
// counts and a firmware version int only).

public enum UniversalTrace {

    /// The R-R transport line: what a device has banked versus what its unit policy can score (#2117).
    /// A WHOOP 5 window is pinned to one transport and a window with no beat on a scorable channel reads
    /// back EMPTY, blanking HRV and respiratory rate while HR-derived values carry on; this tells "banked
    /// nothing" from "banked beats the policy refused". Rides every export because the wearer who needs it
    /// did not know to turn a mode on. Nil for a device the policy does not apply to (WHOOP 4).
    public static func rrTransportLine(strictWhoop5: Bool,
                                       firstRecordedUnix: Int?,
                                       firstScorableUnix: Int?) -> String? {
        guard strictWhoop5 else { return nil }
        guard let firstRecordedUnix else { return "rrTransport recorded=none scorable=none" }
        let recorded = "recorded=\(ConnectionTrace.isoDate(firstRecordedUnix))"
        guard let firstScorableUnix else {
            // Beats on disk, none scorable: history predates transport labelling or sits on an excluded channel.
            return "rrTransport \(recorded) scorable=none unscorableHistory=yes"
        }
        let gapDays = max(0, Int((Double(firstScorableUnix - firstRecordedUnix) / 86_400).rounded()))
        return "rrTransport \(recorded) scorable=\(ConnectionTrace.isoDate(firstScorableUnix)) "
            + "unscorableHistory=\(gapDays > 0 ? "yes" : "no") gapDays=\(gapDays)"
    }

    /// The universal strap-clock line: newest banked-record timestamp vs wall clock, a FUTURE-DATE flag (the
    /// tell of an un-clocked RTC), the optional banked span in days, and the firmware record-layout version.
    /// Timestamps are unix seconds in one wall domain, so the future test is a plain comparison.
    /// `oldestUnix` is optional (a short range reply gives only the upper bound). `firmwareLayout` is the
    /// record-layout version (18/24/25/26), or nil if not yet observed; reported as "v<n>" or "unknown".
    ///
    /// - Parameter futureToleranceSeconds: slack before flagging FUTURE; a minute or two of RTC skew is normal.
    /// - Parameter behindToleranceSeconds: slack before flagging BEHIND (#990); a newest banked record
    ///   naturally trails wall time by hours, so the default is 48 h.
    public static func clockDriftLine(newestUnix: Int,
                                      wallNowUnix: Int,
                                      oldestUnix: Int? = nil,
                                      firmwareLayout: Int? = nil,
                                      futureToleranceSeconds: Int = 120,
                                      behindToleranceSeconds: Int = ConnectionTrace.behindToleranceDefault) -> String {
        let aheadSeconds = newestUnix - wallNowUnix
        var line = "strapClock newest=\(ConnectionTrace.isoDate(newestUnix)) "
            + "wall=\(ConnectionTrace.isoDate(wallNowUnix)) "
            + "newestVsWall=\(ConnectionTrace.signed(aheadSeconds))s"
        if let oldestUnix, oldestUnix < newestUnix {
            // Round to the nearest whole day so a window 60 s shy of three days reads spanDays=3.
            let spanDays = max(0, Int((Double(newestUnix - oldestUnix) / 86_400).rounded()))
            line += " oldest=\(ConnectionTrace.isoDate(oldestUnix)) spanDays=\(spanDays)"
        }
        line += firmwareLayout.map { " firmware=v\($0)" } ?? " firmware=unknown"
        // Verdict shared with ConnectionTrace.clockDriftLine (#990/#987) so the two lines cannot disagree
        // on what counts as a clock fault.
        line += ConnectionTrace.clockVerdict(aheadSeconds: aheadSeconds, newestUnix: newestUnix,
                                             futureToleranceSeconds: futureToleranceSeconds,
                                             behindToleranceSeconds: behindToleranceSeconds)
        return line
    }
}
