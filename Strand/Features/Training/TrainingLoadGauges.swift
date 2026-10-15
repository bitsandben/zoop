import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Weekly load
//
// Cardio and muscular load, each as the full metric anatomy: this week's value, the user's own range,
// the verdict (Low / Optimal / High) and one sentence with the percentage against the norm. All of it
// comes from one `TrainingLoadGauge.Reading`, so the track, the verdict and the sentence cannot disagree.
// Tapping the card opens the explainer.

struct TrainingLoadGauges: View {
    let cardio: TrainingLoadGauge.Reading
    let muscular: TrainingLoadGauge.Reading?
    let effortScale: EffortScale

    @State private var showExplainer = false

    /// Cardio is modelled on the stored 0–100 Effort axis; the card shows the user's scale.
    private var cardioScaled: TrainingLoadGauge.Reading {
        let f = TrainingEffort.value(1, scale: effortScale)
        return .init(state: cardio.state, acute: cardio.acute.map { $0 * f },
                     chronic: cardio.chronic.map { $0 * f },
                     optimalLow: cardio.optimalLow.map { $0 * f }, optimalHigh: cardio.optimalHigh.map { $0 * f },
                     scaleMax: TrainingLoadGauge.niceCeiling(cardio.scaleMax * f))
    }

    var body: some View {
        Button { showExplainer = true } label: {
            ContentCard(LocalizedStringKey(TrainingStrings.gaugesTitle), showsChevron: true) {
                LoadRow(title: LoadStrings.cardio, unit: LoadStrings.effortUnit, reading: cardioScaled,
                        decimals: 1, normWeeks: 6)
                if let muscular {
                    Divider().overlay(StrandPalette.hairline)
                    LoadRow(title: LoadStrings.muscular, unit: LoadStrings.setsUnit, reading: muscular,
                            decimals: 0, normWeeks: TrainingLoadGauge.chronicWindowDays / 7)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(LoadStrings.explainerHint))
        .sheet(isPresented: $showExplainer) { WeeklyLoadExplainerSheet() }
    }
}

/// One load: name and verdict, the track with the user's range, the value against that range, the sentence.
private struct LoadRow: View {
    let title: String
    let unit: String
    let reading: TrainingLoadGauge.Reading
    let decimals: Int
    let normWeeks: Int

    private func format(_ v: Double) -> String { ZoopNumber.decimal(v, digits: decimals) }

    private var verdictColor: Color {
        switch reading.state {
        case .optimal: return StrandPalette.statusPositive
        case .high: return StrandPalette.statusWarning
        case .low: return StrandPalette.textPrimary
        case .calibrating: return StrandPalette.textTertiary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: ZoopSpacing.s)
                Text(LoadStrings.verdict(reading.state)).font(ZoopType.headline).foregroundStyle(verdictColor)
            }
            LoadTrack(reading: reading)
            HStack(alignment: .firstTextBaseline, spacing: ZoopSpacing.xs) {
                Text(verbatim: reading.acute.map(format) ?? "0")
                    .font(ZoopType.metric)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(unit).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
                Spacer(minLength: ZoopSpacing.s)
                if let low = reading.optimalLow, let high = reading.optimalHigh {
                    Text(LoadStrings.range(format(low) + "\u{2013}" + format(high)))
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            Text(LoadStrings.sentence(TrainingLoadGauge.comparison(reading), normWeeks: normWeeks))
                .font(ZoopType.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A flat track from 0 to the reading's scale end: the user's optimal range as a band, a marker at this week.
private struct LoadTrack: View {
    let reading: TrainingLoadGauge.Reading

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.surfaceInset).frame(height: 8)
                if let low = reading.optimalLow, let high = reading.optimalHigh {
                    let x0 = w * TrainingLoadGauge.trackFraction(low, of: reading)
                    let x1 = w * TrainingLoadGauge.trackFraction(high, of: reading)
                    Capsule().fill(StrandPalette.statusPositive.opacity(0.35))
                        .frame(width: max(x1 - x0, 4), height: 8)
                        .offset(x: x0)
                }
                if let value = reading.acute {
                    Circle()
                        .fill(StrandPalette.textPrimary)
                        .overlay(Circle().stroke(StrandPalette.surfaceRaised, lineWidth: 2))
                        .frame(width: 16, height: 16)
                        .offset(x: min(max(w * TrainingLoadGauge.trackFraction(value, of: reading) - 8, 0), w - 16))
                }
            }
            .frame(height: 16)
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }
}

// MARK: - Explainer

struct WeeklyLoadExplainerSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZoopSpacing.xl) {
                    section(LoadStrings.whatTitle, LoadStrings.whatBody)
                    section(LoadStrings.rangeTitle, LoadStrings.rangeBody)
                    VStack(alignment: .leading, spacing: ZoopSpacing.m) {
                        Text(LoadStrings.verdictsTitle).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                        verdict(.low, LoadStrings.lowBody)
                        verdict(.optimal, LoadStrings.optimalBody)
                        verdict(.high, LoadStrings.highBody)
                        verdict(.calibrating, TrainingStrings.takeawayCalibrating)
                    }
                    Text(LoadStrings.descriptiveNote)
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(ZoopSpacing.gutter)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(Text(TrainingStrings.gaugesTitle))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            Text(title).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(body).font(ZoopType.body).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func verdict(_ state: TrainingLoadGauge.State, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LoadStrings.verdict(state)).font(ZoopType.body.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
            Text(body).font(ZoopType.body).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Copy

enum LoadStrings {
    static var cardio: String { String(localized: "zoop.training.load.cardio", defaultValue: "Cardio", bundle: .main) }
    static var muscular: String { String(localized: "zoop.training.load.muscular", defaultValue: "Muscular", bundle: .main) }
    static var effortUnit: String { String(localized: "zoop.training.load.unit.effort", defaultValue: "Effort", bundle: .main) }
    static var setsUnit: String { String(localized: "zoop.training.load.unit.sets", defaultValue: "sets", bundle: .main) }
    static var explainerHint: String {
        String(localized: "zoop.training.load.hint", defaultValue: "Opens what weekly load means", bundle: .main)
    }

    static func verdict(_ state: TrainingLoadGauge.State) -> String {
        switch state {
        case .calibrating: return String(localized: "zoop.training.load.verdict.calibrating", defaultValue: "Calibrating", bundle: .main)
        case .low: return String(localized: "zoop.training.load.verdict.low", defaultValue: "Low", bundle: .main)
        case .optimal: return String(localized: "zoop.training.load.verdict.optimal", defaultValue: "Optimal", bundle: .main)
        case .high: return String(localized: "zoop.training.load.verdict.high", defaultValue: "High", bundle: .main)
        }
    }

    static func range(_ text: String) -> String {
        String(localized: "zoop.training.load.range", defaultValue: "Your range \(text)", bundle: .main)
    }

    /// The one sentence under each load; the calibrating copy when there is no comparison yet.
    static func sentence(_ comparison: TrainingLoadGauge.Comparison?, normWeeks: Int) -> String {
        switch comparison {
        case nil: return TrainingStrings.takeawayCalibrating
        case .same:
            return String(localized: "zoop.training.load.sentence.same",
                          defaultValue: "This week you are training about as much as your average of the last \(normWeeks) weeks.",
                          bundle: .main)
        case .more(let pct):
            return String(localized: "zoop.training.load.sentence.more",
                          defaultValue: "This week you are training \(pct) % more than your average of the last \(normWeeks) weeks.",
                          bundle: .main)
        case .less(let pct):
            return String(localized: "zoop.training.load.sentence.less",
                          defaultValue: "This week you are training \(pct) % less than your average of the last \(normWeeks) weeks.",
                          bundle: .main)
        }
    }

    static var whatTitle: String { String(localized: "zoop.training.load.explain.what.title", defaultValue: "What it shows", bundle: .main) }
    static var whatBody: String {
        String(localized: "zoop.training.load.explain.what.body",
               defaultValue: "Weekly load compares your last 7 days with what you are used to. Cardio uses your daily Effort; muscular counts the working sets in your Lift Log.",
               bundle: .main)
    }
    static var rangeTitle: String { String(localized: "zoop.training.load.explain.range.title", defaultValue: "Your range", bundle: .main) }
    static var rangeBody: String {
        String(localized: "zoop.training.load.explain.range.body",
               defaultValue: "Your range runs from 80 to 130 % of your norm. For cardio the norm is your 6-week average, for muscular your 4-week average.",
               bundle: .main)
    }
    static var verdictsTitle: String { String(localized: "zoop.training.load.explain.verdicts.title", defaultValue: "What the verdict means", bundle: .main) }
    static var lowBody: String {
        String(localized: "zoop.training.load.explain.low",
               defaultValue: "Lighter than usual. Fine for an easy week; fitness does not build from it.", bundle: .main)
    }
    static var optimalBody: String {
        String(localized: "zoop.training.load.explain.optimal",
               defaultValue: "Close to your norm. Steady training that you are used to.", bundle: .main)
    }
    static var highBody: String {
        String(localized: "zoop.training.load.explain.high",
               defaultValue: "Clearly above your norm. Plan easier days so your body can absorb the jump.", bundle: .main)
    }
    static var descriptiveNote: String {
        String(localized: "zoop.training.load.explain.note",
               defaultValue: "Descriptive only: weekly load does not change Recovery or Effort.", bundle: .main)
    }
}
