import Foundation

/// Reshapes a session's stored stage breakdown to a hand-corrected `[newStart, newEnd]` window so a bed-time
/// or wake-time edit updates the hypnogram and totals. Pure; works on whatever `stagesJSON` the session carries.
///
/// A pure onset edit must also drop stages BEFORE the new bed time. Two formats are handled:
///   - segment array `[{"start","end","stage"}]`: clipped to the window; a window that grew at the tail
///     gets a trailing `wake` segment.
///   - minute dict `{"awake","light","deep","rem"}` (imported nights, no timeline): shifted by the
///     duration delta, trimming tail-most stages (awake, light, rem, deep) or adding to awake.
///
/// Returns JSON in the SAME shape it received, or nil when nothing is usable (caller keeps the existing JSON).
public enum SleepWindowReclip {

    public static func reclip(stagesJSON: String?, sessionStart: Int, oldEnd: Int,
                              newStart: Int, newEnd: Int) -> String? {
        guard let stagesJSON, let data = stagesJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let arr = obj as? [[String: Any]] {
            return reclipSegments(arr, newStart: newStart, newEnd: newEnd)
        }
        if let dict = obj as? [String: Any] {
            return reclipMinutes(dict, deltaSeconds: (newEnd - newStart) - (oldEnd - sessionStart))
        }
        return nil
    }

    private static func reclipSegments(_ arr: [[String: Any]], newStart: Int, newEnd: Int) -> String? {
        var out: [[String: Any]] = []
        var maxEnd = newStart
        for seg in arr {
            guard let start = (seg["start"] as? NSNumber)?.intValue,
                  let end = (seg["end"] as? NSNumber)?.intValue,
                  let stage = seg["stage"] as? String,
                  start >= 0, end > start, !stage.isEmpty else { continue }
            if start >= newEnd { continue }                 // wholly after the new wake → drop
            if end <= newStart { continue }                 // wholly before the new bed time → drop
            let clippedStart = max(start, newStart)         // clip the segment spanning the new bed time
            let clippedEnd = min(end, newEnd)               // clip the segment spanning the new wake
            out.append(["start": clippedStart, "end": clippedEnd, "stage": stage])
            maxEnd = max(maxEnd, clippedEnd)
        }
        if newEnd > maxEnd, maxEnd >= newStart {            // window grew → trailing time in bed = awake
            out.append(["start": maxEnd, "end": newEnd, "stage": "wake"])
        }
        // Never return nil here: the store's COALESCE would keep the OLD stages, extending past the new wake.
        if out.isEmpty, newEnd > newStart {
            out.append(["start": newStart, "end": newEnd, "stage": "wake"])
        }
        guard !out.isEmpty, let d = try? JSONSerialization.data(withJSONObject: out) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func reclipMinutes(_ dict: [String: Any], deltaSeconds: Int) -> String? {
        func val(_ k: String) -> Double { (dict[k] as? NSNumber)?.doubleValue ?? 0 }
        var awake = val("awake"), light = val("light"), deep = val("deep"), rem = val("rem")
        let deltaMin = Double(deltaSeconds) / 60.0
        if deltaMin >= 0 {
            awake += deltaMin                               // extra time in bed reads as awake
        } else {
            var trim = -deltaMin                            // remove from the tail-most stages first
            func cut(_ v: Double) -> Double { let c = min(v, max(trim, 0)); trim -= c; return v - c }
            awake = cut(awake); light = cut(light); rem = cut(rem); deep = cut(deep)
        }
        let out: [String: Double] = ["awake": awake, "light": light, "deep": deep, "rem": rem]
        guard out.values.reduce(0, +) > 0,
              let d = try? JSONSerialization.data(withJSONObject: out) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
