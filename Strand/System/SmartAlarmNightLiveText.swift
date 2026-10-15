import Foundation
import StrandAnalytics

/// The words for the smart alarm's live heart-rate stream on the Test Centre night pages. Like the rest of
/// `SmartAlarmNightText`, each line says only what the record holds: a request is "on", not "streaming", and a
/// gap is named without guessing whether the app was suspended or the strap out of range.
extension SmartAlarmNightText {

    /// "Live heart rate: 1,108 values, 2 gaps, off at 06:42 (woken)", or nil when the night never used it.
    static func liveLine(_ n: SmartAlarmNight, now: Int) -> String? {
        guard let l = n.liveStream, !l.toggles.isEmpty else { return nil }
        guard l.firstSampleAt != nil else {
            return String(localized: "Live heart rate: requested, no values received")
        }
        var parts = [String(localized: "Live heart rate: \(l.samplesInWindow.formatted()) values"),
                     gaps(l.gaps.count + (l.openGap(now: now) == nil ? 0 : 1))]
        if let off = l.lastOff {
            parts.append(String(localized: "off at \(clock(off.at)) (\(liveOff(off.reason)))"))
        } else {
            parts.append(String(localized: "still on"))
        }
        return parts.joined(separator: ", ")
    }

    /// "24 from live heart rate, 3 by timer, 1 on app wake", or nil before any evaluation ran in the window.
    static func evaluationsLine(_ n: SmartAlarmNight) -> String? {
        let e = n.evaluationsByTrigger
        guard e.stream + e.timer + e.appWake > 0 else { return nil }
        return String(localized: "Evaluations: \(e.stream) from live heart rate, \(e.timer) by timer, \(e.appWake) on app wake")
    }

    static func gaps(_ count: Int) -> String {
        switch count {
        case 0: return String(localized: "no gaps")
        case 1: return String(localized: "1 gap")
        default: return String(localized: "\(count) gaps")
        }
    }

    static func liveOn(_ r: SmartAlarmNight.LiveReason) -> String {
        switch r {
        case .reconnected: return String(localized: "Live heart rate on again – strap reconnected")
        case .liveScreenClosed: return String(localized: "Live heart rate taken back after the Live screen")
        default: return String(localized: "Live heart rate on – window opens soon")
        }
    }

    static func liveOff(_ r: SmartAlarmNight.LiveReason) -> String {
        switch r {
        case .woken: return String(localized: "woken")
        case .earlyWakePassed: return String(localized: "after the early wake")
        case .windowEnded: return String(localized: "window over")
        case .liveScreenOpened: return String(localized: "Live screen took over")
        case .strapDisconnected: return String(localized: "strap disconnected")
        case .appTerminating: return String(localized: "app closed")
        case .watchdog: return String(localized: "safety cut-off")
        case .settingOff: return String(localized: "turned off")
        case .leftOnByPreviousRun: return String(localized: "left on, turned off at launch")
        case .windowOpening, .reconnected, .liveScreenClosed: return String(localized: "turned off")
        }
    }

    static func liveState(_ raw: String) -> String {
        switch LiveWake.State(rawValue: raw) {
        case .awake: return String(localized: "awake")
        case .light: return String(localized: "light sleep")
        case .deep: return String(localized: "deep sleep")
        case .steady, nil: return String(localized: "no clear signal")
        }
    }

    /// Timeline entries for the stream: each request, the first sample, and each gap.
    static func liveTimeline(_ n: SmartAlarmNight, now: Int) -> [Entry] {
        guard let l = n.liveStream else { return [] }
        var out: [Entry] = []
        for t in l.toggles {
            out.append(t.on
                ? Entry(at: t.at, title: liveOn(t.reason))
                : Entry(at: t.at, title: String(localized: "Live heart rate off – \(liveOff(t.reason))")))
        }
        if let first = l.firstSampleAt {
            out.append(Entry(at: first, title: String(localized: "First live heart rate received")))
        }
        for g in l.gaps + [l.openGap(now: now)].compactMap({ $0 }) {
            out.append(Entry(at: g.start,
                             title: String(localized: "No live heart rate for \(minutes(Double(g.end - g.start) / 60))"),
                             detail: String(localized: "Cause unknown: app suspended, strap out of range or not sending"),
                             tone: .warning))
        }
        return out
    }
}
