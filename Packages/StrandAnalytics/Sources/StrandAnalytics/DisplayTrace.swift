import Foundation

// DisplayTrace.swift - pure values and line formatters for the Display & Performance test mode.
//
// The platform layer reads the live values (UITraitCollection / UIScreen, NSScreen) and feeds
// them to these formatters, so line shapes are pinned by a fixture and read identically in a
// shared report. DisplayMetrics is the resolved value carrier (no UIKit / AppKit, clock, IO or
// PII); DisplayTrace formats the tagged lines; DisplayReadout parses the deviceMetrics line back
// into the id the in-app panel binds (deviceMetricsNow).

/// A platform-resolved snapshot of the display environment, so the formatter has no platform
/// dependency. Optionals are metrics a platform cannot offer; the formatter prints "n/a" for nil.
public struct DisplayMetrics: Sendable, Equatable {
    /// "compact" / "regular", or nil where the platform has no size class (macOS).
    public let horizontalSizeClass: String?
    public let verticalSizeClass: String?
    /// Logical points wide / tall of the key window (or the screen on macOS).
    public let widthPt: Double
    public let heightPt: Double
    /// Backing scale (UIScreen.scale / NSScreen.backingScaleFactor); 0 when unknown.
    public let scale: Double
    /// Safe-area insets in points (top, bottom, leading, trailing); zero where there is no inset.
    public let safeTop: Double
    public let safeBottom: Double
    public let safeLeading: Double
    public let safeTrailing: Double
    /// Dynamic Type content-size category name on iOS (e.g. "L", "AX3"); nil on macOS.
    public let dynamicType: String?
    public let orientation: String
    public let theme: String

    public init(horizontalSizeClass: String?, verticalSizeClass: String?,
                widthPt: Double, heightPt: Double, scale: Double,
                safeTop: Double, safeBottom: Double, safeLeading: Double, safeTrailing: Double,
                dynamicType: String?, orientation: String, theme: String) {
        self.horizontalSizeClass = horizontalSizeClass
        self.verticalSizeClass = verticalSizeClass
        self.widthPt = widthPt; self.heightPt = heightPt; self.scale = scale
        self.safeTop = safeTop; self.safeBottom = safeBottom
        self.safeLeading = safeLeading; self.safeTrailing = safeTrailing
        self.dynamicType = dynamicType; self.orientation = orientation; self.theme = theme
    }
}

/// A snapshot of the on-device data volume (CAPTURE-D / #797), so import-driven lag shows what the
/// screens render over. Counts are read from the store by the caller, not via the Repository.
public struct DataVolume: Sendable, Equatable {
    /// Total raw stream rows in the store (HR + RR + events + biometric streams), the dominant cost.
    public let dbRows: Int
    /// Distinct days that carry imported daily metrics.
    public let importedDays: Int
    public let workouts: Int
    public let lastRenderRows: Int?

    public init(dbRows: Int, importedDays: Int, workouts: Int, lastRenderRows: Int?) {
        self.dbRows = dbRows; self.importedDays = importedDays
        self.workouts = workouts; self.lastRenderRows = lastRenderRows
    }
}

public enum DisplayTrace {

    /// The data-volume line: one upfront `.display` summary (db rows, imported days, workouts, last
    /// render's rows). A nil `lastRenderRows` prints "n/a", not 0.
    public static func dataVolumeLine(_ v: DataVolume) -> String {
        let last = v.lastRenderRows.map(String.init) ?? "n/a"
        return "dataVolume dbRows=\(v.dbRows) importedDays=\(v.importedDays) "
            + "workouts=\(v.workouts) lastRenderRows=\(last)"
    }

    /// The device-metrics line: an upfront `.display` summary of the resolved DisplayMetrics. Numbers
    /// are rounded to whole points; nil size class / Dynamic Type print "n/a".
    public static func deviceMetricsLine(_ m: DisplayMetrics) -> String {
        let h = m.horizontalSizeClass ?? "n/a"
        let v = m.verticalSizeClass ?? "n/a"
        let dt = m.dynamicType ?? "n/a"
        return "deviceMetrics "
            + "size=\(pt(m.widthPt))x\(pt(m.heightPt))pt @\(scaleLabel(m.scale))x "
            + "sizeClass=\(h)/\(v) "
            + "safeArea=t\(pt(m.safeTop)) b\(pt(m.safeBottom)) l\(pt(m.safeLeading)) r\(pt(m.safeTrailing)) "
            + "dynamicType=\(dt) orientation=\(m.orientation) theme=\(m.theme)"
    }

    /// The rolling frame-time summary line: a periodic digest (not per-frame) of the last window.
    /// `hitches` counts frames over the hitch threshold, `worstMs` is the longest frame, `frames` the window size.
    public static func frameSummaryLine(frames: Int, meanMs: Double, p95Ms: Double,
                                        hitches: Int, worstMs: Double, hitchThresholdMs: Double) -> String {
        "frameSummary frames=\(frames) mean=\(ms(meanMs))ms p95=\(ms(p95Ms))ms "
            + "hitches=\(hitches) worst=\(ms(worstMs))ms threshold=\(ms(hitchThresholdMs))ms"
    }

    /// The memory high-water line: the peak resident footprint (MB) seen while the mode was active.
    public static func memoryHighWaterLine(peakMB: Double) -> String {
        "memoryHighWater peak=\(ms(peakMB))MB"
    }

    /// Rounds a point value to a whole number; negative insets clamp to 0 (a read glitch).
    static func pt(_ v: Double) -> String { String(Int((max(0, v)).rounded())) }

    /// Backing scale to one decimal; "?" when unreadable (0).
    static func scaleLabel(_ v: Double) -> String { v > 0 ? String(format: "%.1f", v) : "?" }

    /// One-decimal millisecond / MB value.
    static func ms(_ v: Double) -> String { String(format: "%.1f", max(0, v)) }
}

/// Parses the `.display`-tagged log tail so the live-readout panel reflects exactly the report's
/// metrics line without new published properties. No state, no IO.
public enum DisplayReadout {

    /// The most recent device-metrics summary: everything after the "deviceMetrics " marker on the
    /// last such line in the tail; nil until one is written (on activate and each trait change).
    public static func deviceMetricsNow(taggedTail: [String]) -> String? {
        for line in taggedTail.reversed() {
            if let r = line.range(of: "deviceMetrics ") {
                let frag = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !frag.isEmpty { return frag }
            }
        }
        return nil
    }

    /// The most recent frame-summary fragment (mean / p95 / hitches), or nil before the first window.
    public static func frameSummaryNow(taggedTail: [String]) -> String? {
        for line in taggedTail.reversed() {
            if let r = line.range(of: "frameSummary ") {
                let frag = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !frag.isEmpty { return frag }
            }
        }
        return nil
    }
}
