import Foundation

/// Whether the alarm time a strap reports back can be compared with the one we sent.
/// The two halves are stored under device-less keys (`alarm.lastArmSentEpoch`, `alarm.lastReportedEpoch`),
/// so with several straps registered they may describe different devices, and a cross-strap compare
/// yields a false "strap didn't accept the time" that also feeds `alarm.rejectStreak`. Unless both halves
/// are known to come from the same strap AND the same arm (the reported epoch is only written when the
/// readback decodes, so a decode failure leaves a stale value beside a fresh sent one), this refuses to
/// judge: an unprovable diagnosis is worse than none.
public enum AlarmReadback {

    /// Seconds of slack between the armed time and the readback.
    public static let toleranceS = 120

    public enum Verdict: Equatable {
        /// Same strap, and the readback agrees within `toleranceS`.
        case matches
        /// Same strap, and it does not. The only value that means the strap refused.
        case mismatch
        /// The halves came from different straps; nothing can be concluded.
        case differentStrap
        /// One or both halves predate device attribution.
        case unattributed
        /// The readback is older than the arm it is compared against, so it answered an earlier arm.
        case staleReadback
    }

    /// `sentAt` / `reportedAt` are wall-clock arrival stamps in the platform's own unit; only their
    /// ORDER is read. nil means not recorded, and staleness is then not judged.
    public static func verdict(
        sentEpoch: Int,
        reportedEpoch: Int,
        sentDeviceId: String?,
        reportedDeviceId: String?,
        toleranceS: Int = AlarmReadback.toleranceS,
        sentAt: Double? = nil,
        reportedAt: Double? = nil
    ) -> Verdict {
        guard let sentDeviceId, !sentDeviceId.isEmpty,
              let reportedDeviceId, !reportedDeviceId.isEmpty else { return .unattributed }
        guard sentDeviceId == reportedDeviceId else { return .differentStrap }
        // Checked after attribution: a cross-strap pair is unusable whether or not it is stale, and the
        // strap problem should be named first.
        if let sentAt, let reportedAt, sentAt > 0, reportedAt > 0, reportedAt < sentAt {
            return .staleReadback
        }
        return abs(reportedEpoch - sentEpoch) > toleranceS ? .mismatch : .matches
    }

    /// Suffix the debug export appends after the reported time.
    public static func suffix(_ verdict: Verdict) -> String {
        switch verdict {
        case .matches: return "  ✓ matches"
        case .mismatch: return "  ⚠️ MISMATCH — strap didn't accept the time"
        case .differentStrap: return "  (readback is from a different strap — not comparable)"
        case .unattributed: return "  (no strap recorded for one of these — not comparable)"
        case .staleReadback: return "  (readback predates this arm — not comparable)"
        }
    }

    /// Whether this verdict may advance the consecutive-rejection streak. Only a proven same-strap,
    /// same-arm disagreement counts; unattributed, cross-strap and stale readings leave the streak untouched.
    public static func countsAsRejection(_ verdict: Verdict) -> Bool { verdict == .mismatch }

    /// Whether this verdict is evidence the strap DID accept, which clears the streak.
    public static func clearsRejectionStreak(_ verdict: Verdict) -> Bool { verdict == .matches }
}
