import Foundation
import StrandAnalytics
import StrandDesign
import WhoopProtocol
import WhoopStore

// MARK: - Manual workout form
//
// The state and rules behind the Add / Edit workout sheet, kept out of the view: the span (start + end,
// duration derived), the optional numbers as typed, validation through `WorkoutSource.buildManualRow`
// (the same honest-row rules the engine uses), and the Effort preview.

struct ManualWorkoutForm {
    let editing: WorkoutRow?
    let distanceSystem: UnitSystem

    var sport: String
    var start: Date
    var end: Date
    var avgHrText: String
    var kcalText: String
    /// Distance as entered, in the user's unit (km or mi); converted to stored metres on save (#1195).
    var distanceText: String

    /// A fresh add opens on a valid 45-minute session ending now; an edit pre-fills from the row, seeding the
    /// locale-stable sport name (never a translated word, which would split cross-source dedup per language).
    init(editing: WorkoutRow?, distanceSystem: UnitSystem, now: Date = Date()) {
        self.editing = editing
        self.distanceSystem = distanceSystem
        sport = editing.map { WorkoutSource.editableSport($0.sport) } ?? ""
        start = editing.map { Date(timeIntervalSince1970: TimeInterval($0.startTs)) } ?? now.addingTimeInterval(-45 * 60)
        end = editing.map { Date(timeIntervalSince1970: TimeInterval($0.endTs)) } ?? now
        avgHrText = editing?.avgHr.map(String.init) ?? ""
        kcalText = editing?.energyKcal.map { String(Int($0.rounded())) } ?? ""
        distanceText = editing?.distanceM.map { Self.distanceEntryString($0, system: distanceSystem) } ?? ""
    }

    /// Stored metres as a clean editable number in the user's unit: "5.2", not "5.20".
    static func distanceEntryString(_ meters: Double, system: UnitSystem) -> String {
        let km = meters / 1000.0
        var s = ZoopNumber.decimal(system == .imperial ? km * UnitFormatter.milesPerKilometer : km, digits: 2)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") || s.hasSuffix(",") { s.removeLast() }
        return s
    }

    // MARK: Span

    /// Moving the start keeps the length and carries the end along, clamped so the end stays in the past.
    mutating func moveStart(to picked: Date, now: Date = Date()) {
        let span = end.timeIntervalSince(start)
        let newStart = min(picked, now.addingTimeInterval(-span))
        end = WorkoutSource.endAfterStartMove(oldStart: start, oldEnd: end, newStart: newStart)
        start = newStart
    }

    /// Whole minutes of the span, clamped to the stepper's range; setting it moves the end.
    var durationMinutes: Int {
        get { min(24 * 60, max(1, WorkoutSource.spanDurationMin(start: start, end: end))) }
        set { end = WorkoutSource.endForDuration(start: start, durationMin: newValue) }
    }

    var durationText: String {
        Duration.seconds(durationMinutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)
            .locale(AppLanguage.activeLocale))
    }

    var endText: String {
        end.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLanguage.activeLocale))
    }

    // MARK: Parsed numbers

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
    /// Accepts a decimal comma as typed on a German keyboard.
    private static func number(_ s: String) -> Double? { Double(trimmed(s).replacingOccurrences(of: ",", with: ".")) }

    var avgHr: Int? { Int(Self.trimmed(avgHrText)) }
    var kcal: Double? { Self.number(kcalText) }

    var distanceMeters: Double? {
        guard !Self.trimmed(distanceText).isEmpty, let v = Self.number(distanceText), v >= 0 else { return nil }
        return (distanceSystem == .imperial ? v / UnitFormatter.milesPerKilometer : v) * 1000.0
    }

    var isGPSSport: Bool { WorkoutCatalog.sport(named: sport)?.isDistanceSport == true }

    // MARK: Build and validate

    /// The validated row, or nil when the inputs cannot make an honest one.
    var builtRow: WorkoutRow? {
        if !Self.trimmed(avgHrText).isEmpty && avgHr == nil { return nil }
        if !Self.trimmed(kcalText).isEmpty && kcal == nil { return nil }
        if !Self.trimmed(distanceText).isEmpty && distanceMeters == nil { return nil }
        guard let base = WorkoutSource.buildManualRowFromSpan(start: start, end: end, sport: sport, avgHr: avgHr,
                                                              energyKcal: kcal, distanceM: distanceMeters)
        else { return nil }
        // Carry over captured-but-unexposed fields when editing an existing strap session.
        return WorkoutSource.preservingCaptured(base, from: editing)
    }

    /// True when an edit changes Avg HR on a row whose Effort and zones were captured live (#18).
    var avgHrEditedNote: Bool {
        guard let editing, let built = builtRow else { return false }
        return (editing.strain != nil || editing.zonesJSON != nil) && built.avgHr != editing.avgHr
    }

    /// One line naming what is wrong, or nil when the row builds.
    func validationNote(now: Date = Date()) -> String? {
        guard builtRow == nil else { return nil }
        if Self.trimmed(sport).isEmpty { return String(localized: "Enter a sport.") }
        if start > now { return String(localized: "Start can't be in the future.") }
        if end <= start { return String(localized: "End must be after the start.") }
        if end > now { return String(localized: "End can't be in the future.") }
        if Int(end.timeIntervalSince1970) - Int(start.timeIntervalSince1970) < WorkoutSource.minManualSpanSeconds {
            return String(localized: "A workout must be at least 1 minute.")
        }
        if !Self.trimmed(avgHrText).isEmpty, !(25...250).contains(avgHr ?? -1) {
            return String(localized: "Average HR must be 25-250 bpm.")
        }
        if !Self.trimmed(kcalText).isEmpty, kcal == nil || (kcal ?? -1) < 0 || (kcal ?? 0) > 20_000 {
            return String(localized: "Calories must be 0-20,000.")
        }
        if !Self.trimmed(distanceText).isEmpty, distanceMeters == nil || (distanceMeters ?? 0) > 1_000_000 {
            return distanceSystem == .imperial
                ? String(localized: "Distance must be 0–621 mi.")
                : String(localized: "Distance must be 0–1,000 km.")
        }
        return String(localized: "Check the values and try again.")
    }

    // MARK: Effort preview

    enum EffortPreview: Equatable {
        /// Stored 0–100 Effort and where it comes from.
        case estimated(Double)
        case captured(Double)
        /// No average heart rate typed: the strap's own heart rate scores it after saving.
        case fromStrap
    }

    /// Effort the session will roughly carry. A captured live Effort wins while Avg HR is unchanged; else a
    /// steady-HR estimate through the same `StrainScorer` the live workout uses, labelled as an estimate.
    func effortPreview(hrMax: Int, sex: String, method: StrainScorer.Method) -> EffortPreview {
        if let editing, let strain = editing.strain, avgHr == editing.avgHr { return .captured(strain) }
        guard let hr = avgHr, (25...250).contains(hr), end > start else { return .fromStrap }
        let startTs = Int(start.timeIntervalSince1970)
        let samples = stride(from: startTs, through: Int(end.timeIntervalSince1970), by: 30).map {
            HRSample(ts: $0, bpm: hr)
        }
        guard samples.count >= 2 else { return .fromStrap }
        guard let strain = StrainScorer.strain(samples, maxHR: Double(hrMax), method: method, sex: sex),
              strain.isFinite else { return .fromStrap }
        return .estimated(strain)
    }
}
