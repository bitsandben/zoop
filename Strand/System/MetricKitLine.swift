import Foundation

/// Strap-log lines for the reports iOS hands Zoop through MetricKit: one daily report about the day
/// before, and one after a crash, hang, CPU/disk-write exception or slow launch.
///
/// Nothing is sent anywhere; the lines go only into the strap log a person exports by hand. A field
/// MetricKit omitted is left out, not printed as zero. Pure so `StrandTests` covers it; the
/// subscriber (`MetricKitLog`) is iOS-only.
enum MetricKitLine {

    /// One app-exit reason and its count in the report window.
    struct Exit: Equatable {
        let reason: String
        let count: Int
    }

    /// The daily metric report, reduced to what a battery or crash question needs.
    struct Day: Equatable {
        var begin: Date
        var end: Date
        var appVersion: String
        var foreground: TimeInterval?
        var background: TimeInterval?
        var cpu: TimeInterval?
        var peakMemoryBytes: Double?
        var diskWriteBytes: Double?
        var hangs: Int?
        var exits: [Exit] = []
    }

    static func day(_ d: Day, timeZone: TimeZone = .current) -> String {
        var parts: [String] = []
        if let v = d.foreground { parts.append("foreground \(duration(v))") }
        if let v = d.background { parts.append("background \(duration(v))") }
        if let v = d.cpu { parts.append("CPU \(duration(v))") }
        if let v = d.peakMemoryBytes { parts.append("peak memory \(bytes(v))") }
        if let v = d.diskWriteBytes { parts.append("disk writes \(bytes(v))") }
        if let v = d.hangs { parts.append("hangs \(v)") }
        let exits = d.exits.filter { $0.count > 0 }
        parts.append("exits: " + (exits.isEmpty ? "none" : exits.map { "\($0.reason) \($0.count)" }
            .joined(separator: ", ")))
        return "MetricKit day \(stamp(d.begin, timeZone)) → \(stamp(d.end, timeZone)) (Zoop \(d.appVersion)): "
            + parts.joined(separator: ", ")
    }

    /// A crash, hang, exception or slow-launch report: `kind` names it, `detail` is what iOS said.
    static func diagnostic(_ kind: String, appVersion: String, at: Date, detail: String,
                           timeZone: TimeZone = .current) -> String {
        "MetricKit \(kind) (Zoop \(appVersion), reported \(stamp(at, timeZone))): \(detail)"
    }

    /// "1h 12m", "6m 12s", "40s", and tenths below ten seconds ("2.4s").
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "?" }
        if seconds < 10 {
            let tenths = (seconds * 10).rounded() / 10
            return tenths == tenths.rounded() ? "\(Int(tenths))s" : String(format: "%.1fs", tenths)
        }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    /// Whole megabytes, or gigabytes to one decimal from 1,000 MB up.
    static func bytes(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "?" }
        let mb = value / 1_048_576
        if mb >= 1000 { return String(format: "%.1f GB", mb / 1024) }
        return "\(Int(mb.rounded())) MB"
    }

    private static func stamp(_ date: Date, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
