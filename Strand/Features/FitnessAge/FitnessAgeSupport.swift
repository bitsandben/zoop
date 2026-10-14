#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign

// Small pure helpers shared by the Fitness Age card, screen and rows.

/// Younger reads positive, older warning, the same as your age neutral.
func fitnessTint(delta: Double) -> Color {
    if delta >= 0.5 { return StrandPalette.statusPositive }
    if delta <= -0.5 { return StrandPalette.statusWarning }
    return StrandPalette.textSecondary
}

func fitnessOneDecimal(_ v: Double) -> String {
    v.formatted(.number.precision(.fractionLength(1)))
}

/// Signed with a real minus sign, so the colour is never the only cue for "adds" versus "removes".
func fitnessSignedYears(_ v: Double) -> String {
    let n = fitnessOneDecimal(abs(v))
    if v > 0.05 { return "+" + n }
    if v < -0.05 { return "−" + n }
    return n
}

/// "2.6 years younger than your age" as whole sentences per direction.
func fitnessAgeDeltaLine(fitnessAge: Double, chronoAge: Int) -> String {
    let delta = Double(chronoAge) - fitnessAge
    if abs(delta) < 0.5 { return String(localized: FitnessAgeStrings.sameAge) }
    let years = fitnessOneDecimal(abs(delta))
    return String(localized: delta > 0 ? FitnessAgeStrings.younger(years) : FitnessAgeStrings.older(years))
}

/// Stored series days are `yyyy-MM-dd` in the user's calendar.
func fitnessDayDate(_ day: String) -> Date? {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: day)
}

/// Which way a factor's signal is moving, judged on its last 14 days against the 46 before.
enum FitnessTrend {
    case improving(up: Bool), worsening(up: Bool), steady

    static func of(_ series: [(day: String, value: Double)], lowerIsBetter: Bool) -> FitnessTrend {
        guard series.count >= 6 else { return .steady }
        let cutoff = Repository.localDayKey(Date().addingTimeInterval(-14 * 86_400))
        let recent = series.filter { $0.day >= cutoff }.map(\.value)
        let before = series.filter { $0.day < cutoff }.map(\.value)
        guard !recent.isEmpty, !before.isEmpty else { return .steady }
        let r = recent.reduce(0, +) / Double(recent.count), b = before.reduce(0, +) / Double(before.count)
        // Under 3 % is within day-to-day noise, so it reads as steady.
        guard b != 0, abs(r - b) / abs(b) >= 0.03 else { return .steady }
        let up = r > b
        return up != lowerIsBetter ? .improving(up: up) : .worsening(up: up)
    }

    var word: LocalizedStringResource {
        switch self {
        case .improving: return FitnessAgeStrings.trendImproving
        case .worsening: return FitnessAgeStrings.trendWorsening
        case .steady: return FitnessAgeStrings.trendSteady
        }
    }

    var icon: String {
        switch self {
        case .improving(let up), .worsening(let up):
            return up ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill"
        case .steady: return "arrow.right.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .improving: return StrandPalette.statusPositive
        case .worsening: return StrandPalette.statusWarning
        case .steady: return StrandPalette.textSecondary
        }
    }
}
#endif
