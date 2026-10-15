import Foundation

// GuidedCaptureProgress.swift - the pure state machine for the guided "wear it N nights" Sleep (and
// N days Battery) capture. No scheduling or IO. A night with no data is a recorded gap, never a stall.

public enum GuidedCaptureProgress: Equatable, Sendable {
    case capturing(done: Int, target: Int)
    case complete

    /// `nightsWithData` = nights (or days) with usable data; `nightsElapsed` = calendar units since
    /// start. Complete once enough nights have data, regardless of gaps.
    public static func evaluate(target: Int, nightsWithData: Int, nightsElapsed: Int) -> GuidedCaptureProgress {
        if nightsWithData >= target { return .complete }
        return .capturing(done: nightsWithData, target: target)
    }

    public static func label(for state: GuidedCaptureProgress) -> String {
        switch state {
        case .complete: return "Capture complete. Tap Report to export."
        case let .capturing(done, target): return "Captured \(done) of \(target) nights. Wear it again tonight."
        }
    }

    public static func gapNudge() -> String { "No data last night. Wear the strap tonight to continue." }
}
