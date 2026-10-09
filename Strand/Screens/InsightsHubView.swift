import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Insights Hub (v5)
//
// The headline n-of-1 "what actually moves YOUR recovery" surface. Two halves, both
// pure association on the user's own logged days — never advice, diagnosis, or cause:
//
//  1. WHAT MOVES YOUR CHARGE — the unified, LAG-AWARE EffectRanker feed. For each
//     journal behaviour × the selected outcome it keeps the strongest honest lag
//     ({0,+1,+2} days), so each row reads "shows up the next morning" rather than
//     pretending everything is same-day. Each behaviour is one compact row in a single
//     card (name, signed relative change, with/without/lag summary); tapping it expands
//     the plain-language sentence, with/without day counts, the effect size in words, and
//     a Solid / Building / Calibrating confidence pill — NOT a bare "significant" stamp.
//     All copy is built here from the engine's numbers so it localizes as whole sentences.
//
//  2. ALCOHOL / CAFFEINE DOSE-RESPONSE — the personal DoseResponseEngine curve. A
//     per-user slope that SHRINKS toward a documented population prior until enough
//     nights accrue. The card plots the shrunk curve, states "each extra drink ≈ −N
//     for you" (honest when still prior-dominated, or when YOUR data contradicts the
//     prior), and an evening "damage forecast" preview — "a 2nd drink tonight ≈ −X
//     Charge tomorrow" — composed from the curve's per-unit Δ on the latest Charge.
//
// SELF-CONTAINED: this screen owns its own load/derive (InsightsHubViewModel) and takes
// the Repository via @EnvironmentObject — it does NOT edit AppModel / the central nav.
// Wave 3 surfaces it as the head of the Insights hub (see 'wiringNeeded').
//
// All maths lives in StrandAnalytics (EffectRanker / DoseResponseEngine / DoseResponsePriors);
// this view loads the series, shapes the engine inputs, and presents honestly.

struct InsightsHubView: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var model = InsightsHubViewModel()

    /// The currently-selected outcome for the ranked feed (Charge / HRV / Rest / RHR).
    @State private var outcome: InsightsHubViewModel.Outcome = .recovery
    /// The behaviour whose row is expanded into its detail, if any (one at a time).
    @State private var expanded: String?

    var body: some View {
        ScreenScaffold(title: "Insights",
                       subtitle: "Patterns in your own data: association, not cause.",
                       quietSubtitle: true,
                       // PERF (scroll): lazy column — byte-identical layout (LazyVStack == eager VStack
                       // alignment/spacing/header). The content is one inner eager VStack, so the staggered
                       // mover reveal is unchanged; this only defers building that stack until it scrolls in.
                       lazy: true) {
            if !model.loaded {
                ComingSoon(what: "Reading your journal and outcomes…")
            } else {
                VStack(alignment: .leading, spacing: ZoopMetrics.sectionSpacing) {
                    moversSection
                    doseSection
                    methodNote
                }
            }
        }
        .task(id: repo.refreshSeq) { await model.load(repo: repo) }
        .onChangeCompat(of: outcome) {
            expanded = nil
            model.rankFor($0)
        }
    }

    // MARK: - What moves your Charge (ranked, lag-aware)

    private var moversSection: some View {
        VStack(alignment: .leading, spacing: ZoopMetrics.gap) {
            // Header and the 4-segment outcome control each get their own row — one HStack
            // crushed the pill control on narrow widths and truncated the segment labels.
            // The title is one whole localized phrase per metric, so German keeps its noun
            // capitalisation and article ("Was deinen Schlaf beeinflusst").
            SectionHeader(LocalizedStringKey(outcome.moversTitle),
                          overline: "Ranked · your data")
            SegmentedPillControl(InsightsHubViewModel.Outcome.allCases, selection: $outcome) { $0.label }
                .accessibilityLabel("Outcome metric")
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.ranked.isEmpty {
                ZoopCard {
                    Text(String(localized: "Not enough overlap between your journal answers and \(outcome.outcomeName) yet. Keep logging. Each behaviour needs days both with and without it before Zoop can read its effect."))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                moversList
                    .staggeredAppear(index: 0)
            }
        }
    }

    /// Every ranked behaviour as one compact row inside a single card, separated by hairlines.
    private var moversList: some View {
        ZoopCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.ranked.enumerated()), id: \.element.behavior) { index, r in
                    if index > 0 {
                        Divider()
                            .overlay(StrandPalette.hairline)
                            .padding(.leading, ZoopMetrics.cardPadding)
                    }
                    moverRow(r)
                }
            }
        }
    }

    /// One ranked, lag-aware mover row: habit name, a signed relative change tinted by whether
    /// it helps the selected metric, and a with/without/lag summary. Tapping toggles the detail.
    private func moverRow(_ r: RankedEffect) -> some View {
        let e = r.effect
        let isOpen = expanded == r.behavior
        let tint = deltaColor(e)
        return VStack(alignment: .leading, spacing: ZoopMetrics.space3) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    expanded = isOpen ? nil : r.behavior
                }
            } label: {
                HStack(alignment: .center, spacing: ZoopMetrics.space3) {
                    VStack(alignment: .leading, spacing: ZoopMetrics.space1) {
                        Text(Self.habitName(r.behavior))
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(summaryLine(r))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    Spacer(minLength: ZoopMetrics.space2)
                    Text(deltaText(e))
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(tint)
                    Image(systemName: "chevron.down")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isOpen ? [.isButton, .isSelected] : .isButton)

            if isOpen {
                moverDetail(r, tint: tint)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, ZoopMetrics.cardPadding)
        .padding(.vertical, ZoopMetrics.space3)
    }

    /// The expanded read: the plain-language sentence, with/without side by side with their
    /// day counts, and the effect size in words with its confidence tier.
    private func moverDetail(_ r: RankedEffect, tint: Color) -> some View {
        let e = r.effect
        let dText = e.cohensD.formatted(.number.precision(.fractionLength(2)))
        return VStack(alignment: .leading, spacing: ZoopMetrics.space3) {
            Text(detailSentence(r))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: ZoopMetrics.space2) {
                groupColumn(label: "With", value: outcome.format(e.meanWith),
                            days: e.nWith, accent: tint)
                groupColumn(label: "Without", value: outcome.format(e.meanWithout),
                            days: e.nWithout, accent: StrandPalette.textPrimary)
            }

            HStack(alignment: .top, spacing: ZoopMetrics.space3) {
                VStack(alignment: .leading, spacing: ZoopMetrics.space1) {
                    Text(Self.effectPhrase(e.cohensD))
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(String(localized: "Cohen’s d \(dText): the size of the gap compared with your usual day-to-day spread."))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: ZoopMetrics.space2)
                ScoreStatePill(Self.scoreState(r.confidence))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func groupColumn(label: LocalizedStringKey, value: String, days: Int, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: ZoopMetrics.space1) {
            Text(label).strandOverline()
            Text(value)
                .font(StrandFont.title2)
                .monospacedDigit()
                .foregroundStyle(accent)
            Text(String(localized: "\(days) days"))
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(ZoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZoopPanelSurface(cornerRadius: ZoopVisualStyle.compactRadius))
    }

    // MARK: - Mover copy (built here from the engine's numbers, fully localized)

    /// Green when the behaviour lines up with the metric moving the good way, warning when the
    /// bad way, neutral when there is no difference.
    private func deltaColor(_ e: BehaviorEffect) -> Color {
        guard e.delta != 0 else { return StrandPalette.textSecondary }
        return (e.delta > 0) == outcome.higherIsBetter ? StrandPalette.statusPositive : StrandPalette.statusWarning
    }

    /// Signed relative change ("+22 %" / "−8 %"); falls back to signed metric units when the
    /// without-mean is zero and a relative change is undefined.
    private func deltaText(_ e: BehaviorEffect) -> String {
        if let pct = e.pctChange { return Self.percent(pct / 100, signed: true) }
        let sign = e.delta > 0 ? "+" : (e.delta < 0 ? "\u{2212}" : "")
        return sign + outcome.format(abs(e.delta))
    }

    /// Unsigned magnitude for the sentence ("22 %" / "4 ms").
    private func magnitudeText(_ e: BehaviorEffect) -> String {
        if let pct = e.pctChange { return Self.percent(abs(pct) / 100, signed: false) }
        return outcome.format(abs(e.delta))
    }

    private func summaryLine(_ r: RankedEffect) -> String {
        let with = outcome.format(r.effect.meanWith)
        let without = outcome.format(r.effect.meanWithout)
        let lag = Self.lagLabel(r.lag)
        return String(localized: "\(with) with · \(without) without · \(lag)")
    }

    /// Whole-sentence variants per direction (never a stitched "higher"/"lower" fragment), then
    /// a separate whole sentence for when the effect shows up.
    private func detailSentence(_ r: RankedEffect) -> String {
        let e = r.effect
        let habit = Self.habitName(r.behavior)
        let metric = outcome.possessive
        let mag = magnitudeText(e)
        let with = outcome.format(e.meanWith)
        let without = outcome.format(e.meanWithout)
        let main: String
        if e.delta > 0 {
            main = String(localized: "On days with “\(habit)”, \(metric) was \(mag) higher (\(with) vs. \(without)).")
        } else if e.delta < 0 {
            main = String(localized: "On days with “\(habit)”, \(metric) was \(mag) lower (\(with) vs. \(without)).")
        } else {
            main = String(localized: "On days with “\(habit)”, \(metric) was about the same (\(with) vs. \(without)).")
        }
        let timing: String
        switch r.lag {
        case 0:  timing = String(localized: "Compared on the same day.")
        case 1:  timing = String(localized: "Measured the next morning.")
        default: timing = String(localized: "Measured \(r.lag) days later.")
        }
        return main + " " + timing
    }

    // MARK: - Alcohol / caffeine dose-response

    private var doseSection: some View {
        VStack(alignment: .leading, spacing: ZoopMetrics.gap) {
            SectionHeader("Dose-response", overline: "Alcohol & caffeine · your curve")
            if model.doseCards.isEmpty {
                ZoopCard {
                    Text(String(localized: "Log alcohol or late caffeine with an amount and Zoop fits a personal dose curve: how much each extra unit tends to move your numbers. Until then it shows typical patterns, clearly labelled as not yet yours."))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ForEach(Array(model.doseCards.enumerated()), id: \.element.id) { index, card in
                    DoseResponseCardView(card: card)
                        .staggeredAppear(index: index)
                }
            }
        }
    }

    // MARK: - Method / honesty note

    private var methodNote: some View {
        ZoopCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("How to read this").strandOverline()
                Text(String(localized: "Everything here is a pattern in your own logged days: an association with an effect size and confidence, never a cause or a diagnosis. Population patterns are shown as \u{201C}typical\u{201D} and are always overridden by your own data once you have enough of it. Approximations, not WHOOP\u{2019}s scores; not a medical device."))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Helpers

    /// Map the engine's ScoreConfidence tier to the design-system ScoreState pill.
    static func scoreState(_ c: ScoreConfidence) -> ScoreState {
        switch c {
        case .solid:       return .solid
        case .building:    return .building
        case .calibrating: return .calibrating
        }
    }

    /// Cohen's d → conventional magnitude, phrased as a whole noun phrase ("moderate effect").
    static func effectPhrase(_ d: Double) -> String {
        switch abs(d) {
        case ..<0.2: return String(localized: "Negligible effect")
        case ..<0.5: return String(localized: "Small effect")
        case ..<0.8: return String(localized: "Moderate effect")
        default:     return String(localized: "Large effect")
        }
    }

    /// When the effect shows up, as a short row label.
    static func lagLabel(_ lag: Int) -> String {
        switch lag {
        case 0:  return String(localized: "same day")
        case 1:  return String(localized: "next morning")
        default: return String(localized: "after \(lag) days")
        }
    }

    /// Locale-aware percent ("22 %" in German, "22%" in English) with a true minus sign.
    static func percent(_ fraction: Double, signed: Bool) -> String {
        var style = FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0))
        if signed { style = style.sign(strategy: .always()) }
        return fraction.formatted(style).replacingOccurrences(of: "-", with: "\u{2212}")
    }

    /// Display name for a journal behaviour. The stored question is an opaque engine key and is
    /// never rewritten; the starter questions get a short noun label here, and anything else is
    /// looked up in the catalog (so imported/custom questions that have a translation show it).
    static func habitName(_ question: String) -> String {
        switch question {
        case "Did you drink any alcohol?":             return String(localized: "Alcohol")
        case "Did you have caffeine late in the day?": return String(localized: "Late caffeine")
        case "Did you view a screen in bed?":          return String(localized: "Screen in bed")
        case "Did you eat close to bedtime?":          return String(localized: "Late meal")
        case "Did you feel stressed?":                 return String(localized: "Stress")
        case "Did you use a sauna?":                   return String(localized: "Sauna")
        case "Did you share your bed?":                return String(localized: "Shared bed")
        case "Did you feel sick or ill?":              return String(localized: "Feeling ill")
        case "Did you take magnesium?":                return String(localized: "Magnesium")
        case "Did you read before bed?":               return String(localized: "Reading before bed")
        default:                                       return String(localized: String.LocalizationValue(question))
        }
    }
}

// MARK: - Dose-response card
//
// The headline alcohol/caffeine surface: the prior-shrunk curve, the per-unit read,
// the confidence pill, the honesty banner, and an evening "damage forecast" preview
// driven by a tiny dose stepper. The forecast is a what-if on the user's own latest
// Charge — "a 2nd drink tonight tends to line up with about −7 on tomorrow's Charge
// for you" — never a recommendation to drink or abstain.

private struct DoseResponseCardView: View {
    let card: InsightsHubViewModel.DoseCard

    /// The "what if I have one more" preview dose, defaulting to one above the typical
    /// starting point so the headline reads as a 2nd-drink forecast out of the box.
    @State private var previewDose: Int = 2

    private var domain: DomainTheme { card.outcome == .hrv ? .rest : .charge }

    var body: some View {
        let r = card.response
        ZoopCard(tint: domain.color) {
            VStack(alignment: .leading, spacing: ZoopMetrics.gap) {
                header(r)

                // The honest read (prior / yours / contradicts-prior), built here from the
                // engine's numbers so it is fully localized.
                Text(card.readSentence)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // The prior-shrunk curve (dose on x, modelled outcome Δ on y).
                DoseCurveChart(points: r.curve, accent: domain.color,
                               doseLabel: { card.chartDoseLabel($0) },
                               valueText: { card.signed($0) })
                    .frame(height: 132)
                    .accessibilityLabel(String(localized: "Dose-response curve. \(card.readSentence)"))

                if r.priorDominated {
                    honestyBanner(card.priorBanner)
                }

                if card.timingProxy {
                    Text("\u{201C}Dose\u{201D} here is timing (later in the day = stronger), not milligrams.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().overlay(StrandPalette.hairline)

                damageForecast(r)
            }
        }
    }

    // MARK: Header

    private func header(_ r: DoseResponse) -> some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 8) {
                Image(systemName: card.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(domain.color)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(card.title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            Spacer(minLength: 8)
            ScoreStatePill(InsightsHubView.scoreState(r.confidence))
        }
    }

    // MARK: Evening damage forecast (what-if on the user's latest Charge)

    @ViewBuilder private func damageForecast(_ r: DoseResponse) -> some View {
        // The Δ of going from the typical starting dose (1) to the previewed dose, applied
        // to the user's most recent outcome value as an honest "where you'd likely land".
        let fromDose = 1
        let delta = r.delta(fromDose: fromDose, toDose: previewDose)
        let projected = card.latestOutcome.map { max(0, min(card.outcomeCeiling, $0 + delta)) }
        let stepLabel = previewDose <= 1 ? String(localized: "no extra") : card.stepLabel(previewDose)

        VStack(alignment: .leading, spacing: ZoopMetrics.gap) {
            // Overline and the dose stepper each get their own row — sharing one HStack
            // compressed the 0/1/2/3+ stepper and truncated its segments on narrow widths.
            Text(card.forecastOverline).strandOverline()
                .frame(maxWidth: .infinity, alignment: .leading)
            SegmentedPillControl(card.doseChoices, selection: $previewDose) { card.doseChoiceLabel($0) }
                .accessibilityLabel("Preview dose")
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(card.forecastSentence(dose: previewDose, delta: delta))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: ZoopMetrics.gap)],
                      alignment: .leading, spacing: ZoopMetrics.gap) {
                StatTile(label: LocalizedStringKey(card.perUnitLabel),
                         value: card.signed(r.perUnit),
                         caption: r.priorDominated ? String(localized: "typical") : String(localized: "your data"),
                         accent: r.perUnit < 0 ? StrandPalette.statusCritical : StrandPalette.statusPositive)
                StatTile(label: LocalizedStringKey(String(localized: "Tomorrow\u{2019}s \(card.outcome.outcomeName)")),
                         value: projected.map { card.format($0) } ?? "—",
                         caption: projected != nil ? String(localized: "projected · \(stepLabel)") : String(localized: "needs a recent day"),
                         accent: domain.color)
            }
        }
    }

    // MARK: Bits

    private func honestyBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: ZoopMetrics.space2) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
            Text(text)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(ZoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZoopPanelSurface(cornerRadius: 8))
    }
}

// MARK: - Dose curve chart
//
// A compact line+area chart of the prior-shrunk curve: dose on x (0…max), the modelled
// outcome DELTA on y. Drawn with the house Path idiom (no extra dependency) so it sits
// in the design system. Zero-line is marked; the line is tinted to the domain colour.

private struct DoseCurveChart: View {
    let points: [DoseCurvePoint]
    let accent: Color
    /// The dose axis label under the finger ("2 drinks" / "Noon").
    let doseLabel: (Int) -> String
    /// The signed, unit-bearing modelled change ("−7 %" / "+1.5 ms").
    let valueText: (Double) -> String
    /// The dose under the finger while scrubbing.
    @State private var scrubIndex: Int?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let deltas = points.map(\.outcomeDelta)
            let maxAbs = max(1.0, (deltas.map(abs).max() ?? 1.0))
            // Symmetric y range around zero so the sign reads honestly.
            let yFor: (Double) -> CGFloat = { d in
                let t = (d / maxAbs + 1) / 2          // 0 (most negative) … 1 (most positive)
                return h - CGFloat(t) * h
            }
            let n = max(1, points.count - 1)
            let xFor: (Int) -> CGFloat = { i in CGFloat(i) / CGFloat(n) * w }
            let zeroY = yFor(0)

            ZStack(alignment: .topLeading) {
                // Zero baseline.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: zeroY))
                    p.addLine(to: CGPoint(x: w, y: zeroY))
                }
                .stroke(StrandPalette.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                // Filled area between the curve and the zero line.
                Path { p in
                    guard !points.isEmpty else { return }
                    p.move(to: CGPoint(x: xFor(0), y: zeroY))
                    for (i, pt) in points.enumerated() {
                        p.addLine(to: CGPoint(x: xFor(i), y: yFor(pt.outcomeDelta)))
                    }
                    p.addLine(to: CGPoint(x: xFor(points.count - 1), y: zeroY))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [accent.opacity(0.22), accent.opacity(0.03)],
                                     startPoint: .top, endPoint: .bottom))

                // The curve line.
                Path { p in
                    for (i, pt) in points.enumerated() {
                        let point = CGPoint(x: xFor(i), y: yFor(pt.outcomeDelta))
                        if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                    }
                }
                .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                // Dose markers.
                ForEach(points.indices, id: \.self) { i in
                    Circle()
                        .fill(accent)
                        .frame(width: 5, height: 5)
                        .position(x: xFor(i), y: yFor(points[i].outcomeDelta))
                }

                // Scrub readout: the dose under the finger and its modelled change.
                if let i = scrubIndex, points.indices.contains(i) {
                    ChartScrubReadout(
                        x: xFor(i), y: yFor(points[i].outcomeDelta), container: geo.size,
                        value: valueText(points[i].outcomeDelta),
                        label: doseLabel(points[i].dose),
                        accent: accent)
                }
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .contentShape(Rectangle())
            .zoopChartScrub(onChange: { location in
                scrubIndex = ChartHoverMath.nearestIndex(toX: location.x, count: points.count, width: w)
            }, onEnd: { scrubIndex = nil })
        }
        .accessibilityElement()
    }
}

// MARK: - View-model
//
// Self-contained: loads the journal (behaviour → days), dose rows (under the dedicated
// noop-journal-dose source), and the outcome series (imported metricSeries ∪ DailyMetric
// fallback, exactly as InsightsView), then runs EffectRanker for the ranked feed and
// DoseResponseEngine for each dosed behaviour the user has data for. No edits to AppModel.

@MainActor
final class InsightsHubViewModel: ObservableObject {

    // MARK: Outcome

    enum Outcome: String, CaseIterable, Identifiable {
        case recovery, hrv, sleep, rhr
        var id: String { rawValue }
        var label: String {
            switch self {
            case .recovery: return String(localized: "Charge")
            case .hrv:      return "HRV"
            case .sleep:    return String(localized: "Rest")
            case .rhr:      return "RHR"
            }
        }
        /// metricSeries key.
        var key: String {
            switch self {
            case .recovery: return "recovery"
            case .hrv:      return "hrv"
            case .sleep:    return "sleep_performance"
            case .rhr:      return "rhr"
            }
        }
        /// The engine's outcome label (carried onto each RankedEffect).
        var outcomeName: String {
            switch self {
            case .recovery: return String(localized: "Charge")
            case .hrv:      return "HRV"
            case .sleep:    return String(localized: "Rest")
            case .rhr:      return String(localized: "Resting HR")
            }
        }
        var higherIsBetter: Bool { self != .rhr }
        var domain: DomainTheme {
            switch self {
            case .recovery: return .charge
            case .hrv, .sleep: return .rest
            case .rhr: return .stress
            }
        }
        /// The ranked-feed header, one whole phrase per metric so each language can inflect the
        /// noun and its article itself.
        var moversTitle: String {
            switch self {
            case .recovery: return String(localized: "What moves your Charge")
            case .hrv:      return String(localized: "What moves your HRV")
            case .sleep:    return String(localized: "What moves your Rest")
            case .rhr:      return String(localized: "What moves your resting HR")
            }
        }
        /// The metric with its possessive, for use inside a sentence ("your Charge").
        var possessive: String {
            switch self {
            case .recovery: return String(localized: "your Charge")
            case .hrv:      return String(localized: "your HRV")
            case .sleep:    return String(localized: "your Rest")
            case .rhr:      return String(localized: "your resting HR")
            }
        }
        /// Locale-aware value with its unit ("48 %" in German, "48%" in English).
        func format(_ v: Double, fractionDigits: Int = 0) -> String {
            switch self {
            case .recovery, .sleep:
                return (v / 100).formatted(.percent.precision(.fractionLength(0...fractionDigits)))
            case .hrv:
                return "\(v.formatted(.number.precision(.fractionLength(0...fractionDigits)))) ms"
            case .rhr:
                return "\(v.formatted(.number.precision(.fractionLength(0...fractionDigits)))) bpm"
            }
        }
    }

    // MARK: Published state

    @Published private(set) var loaded = false
    @Published private(set) var ranked: [RankedEffect] = []
    @Published private(set) var doseCards: [DoseCard] = []

    // MARK: Loaded inputs (kept so the outcome segmented control can re-rank cheaply)

    private var behaviours: [String: Set<String>] = [:]
    /// Per behaviour, the days it was logged NO — the only legitimate control group.
    private var controls: [String: Set<String>] = [:]
    private var outcomeByKey: [String: [String: Double]] = [:]
    private var currentOutcome: Outcome = .recovery

    /// The source id dose rows are parked under (mirrors MoodStore's noop-mood isolation).
    static let doseSource = "noop-journal-dose"

    private let outcomeKeys = ["recovery", "hrv", "sleep_performance", "rhr"]

    // MARK: Load

    func load(repo: Repository) async {
        // Journal → behaviour → days (only "yes" answers count as the behaviour occurring).
        let entries = await repo.journalEntries()
        // Yes days and NO days, kept apart. A day with no journal row for the question lands in
        // neither, so an unanswered day is never counted as a No (BehaviorInsights.effect).
        var byBehaviour: [String: Set<String>] = [:]
        var controlsByBehaviour: [String: Set<String>] = [:]
        for e in entries {
            if e.answeredYes { byBehaviour[e.question, default: []].insert(e.day) }
            else { controlsByBehaviour[e.question, default: []].insert(e.day) }
        }

        // Outcome series: imported metricSeries ∪ the DailyMetric column fallback so an
        // account-free (strap-only) user still gets effects — the exact contract InsightsView uses.
        let mergedDays = repo.days
        var byKey: [String: [String: Double]] = [:]
        for key in outcomeKeys {
            let s = await repo.series(key: key, source: "my-whoop")
            var dict: [String: Double] = [:]
            for row in s { dict[row.day] = row.value }
            for d in mergedDays where dict[d.day] == nil {
                if let v = Self.dailyOutcome(key: key, day: d) { dict[d.day] = v }
            }
            byKey[key] = dict
        }

        // Dose rows per dosed behaviour, under the dedicated dose source, keyed by the
        // behaviour's storage key. A logged "yes" with no dose row reads as dose = 1
        // (back-compatible), so we union the behaviour's logged days at dose 1 with any
        // explicit dose rows (explicit wins).
        var doseByBehaviour: [DosedBehavior: [String: Int]] = [:]
        for behavior in DosedBehavior.allCases {
            let key = Self.doseKey(for: behavior)
            let rows = await repo.series(key: key, source: Self.doseSource)
            var doses: [String: Int] = [:]
            // Back-compat: any logged "yes" day for a matching journal question starts at dose 1.
            for (question, days) in byBehaviour where Self.matches(behavior, question: question) {
                for day in days { doses[day] = max(doses[day] ?? 0, 1) }
            }
            // Explicit dose rows override.
            for row in rows { doses[row.day] = Int(row.value.rounded()) }
            if !doses.isEmpty { doseByBehaviour[behavior] = doses }
        }

        // Build the dose cards from the engine (alcohol first, then caffeine).
        var cards: [DoseCard] = []
        for behavior in DosedBehavior.allCases {
            guard let doses = doseByBehaviour[behavior] else { continue }
            let outcomeName = DoseResponsePriors.defaultOutcome(for: behavior)
            let outcomeKey = Self.outcomeKey(forEngineName: outcomeName)
            let outcomeDays = byKey[outcomeKey] ?? [:]
            guard let response = DoseResponseEngine.estimate(behavior: behavior,
                                                             doseByDay: doses,
                                                             outcomeByDay: outcomeDays) else { continue }
            let latest = outcomeDays.keys.max().flatMap { outcomeDays[$0] }
            cards.append(DoseCard(behavior: behavior, response: response, latestOutcome: latest))
        }

        self.behaviours = byBehaviour
        self.controls = controlsByBehaviour
        self.outcomeByKey = byKey
        self.doseCards = cards
        self.loaded = true
        rankFor(currentOutcome)
    }

    /// Re-rank the mover feed for a (possibly new) outcome selection — cheap, no DB.
    func rankFor(_ outcome: Outcome) {
        currentOutcome = outcome
        let outcomeDays = outcomeByKey[outcome.key] ?? [:]
        ranked = EffectRanker.rank(behaviors: behaviours,
                                   controls: controls,
                                   outcomeByDay: outcomeDays,
                                   outcome: outcome.outcomeName)
    }

    // MARK: Static shaping helpers

    /// The merged DailyMetric column backing an outcome key (strap-only fallback). sleep_performance
    /// has no daily column, so it stays import-only — never seeded here (matches InsightsView).
    private static func dailyOutcome(key: String, day d: DailyMetric) -> Double? {
        switch key {
        case "recovery": return d.recovery
        case "hrv":      return d.avgHrv
        case "rhr":      return d.restingHr.map(Double.init)
        default:         return nil
        }
    }

    /// The metricSeries key a DoseResponsePriors outcome NAME maps to ("Charge"→recovery, "HRV"→hrv).
    nonisolated static func outcomeKey(forEngineName name: String) -> String {
        switch name {
        case "Charge": return "recovery"
        case "HRV":    return "hrv"
        case "Rest":   return "sleep_performance"
        case "Resting HR": return "rhr"
        default:       return "recovery"
        }
    }

    /// The display Outcome for a DoseResponsePriors outcome NAME (via its metricSeries key).
    nonisolated static func outcome(forEngineName name: String) -> Outcome {
        switch outcomeKey(forEngineName: name) {
        case "hrv":               return .hrv
        case "sleep_performance": return .sleep
        case "rhr":               return .rhr
        default:                  return .recovery
        }
    }

    /// The dose storage key for a behaviour (its raw enum value — the stable, cross-platform key).
    static func doseKey(for behavior: DosedBehavior) -> String { "dose_\(behavior.rawValue)" }

    /// Whether a journal question is the dosed behaviour (so its yes-days back-fill dose = 1).
    static func matches(_ behavior: DosedBehavior, question: String) -> Bool {
        let q = question.lowercased()
        switch behavior {
        case .alcohol:  return q.contains("alcohol") || q.contains("drink")
        case .caffeine: return q.contains("caffeine") || q.contains("coffee")
        }
    }

    // MARK: Dose card view-data

    struct DoseCard: Identifiable {
        let behavior: DosedBehavior
        let response: DoseResponse
        /// The user's most recent outcome value (for the evening damage forecast anchor).
        let latestOutcome: Double?

        var id: String { behavior.rawValue }
        /// The metric the engine expressed this curve in, as a display Outcome.
        var outcome: Outcome { InsightsHubViewModel.outcome(forEngineName: response.outcome) }

        var title: String {
            switch behavior {
            case .alcohol:  return String(localized: "Alcohol")
            case .caffeine: return String(localized: "Caffeine")
            }
        }
        var symbol: String {
            switch behavior {
            case .alcohol:  return "wineglass"
            case .caffeine: return "cup.and.saucer.fill"
            }
        }
        var timingProxy: Bool { behavior == .caffeine }

        /// Clamp ceiling for the projected outcome (Charge/Rest are 0–100; HRV uncapped-ish).
        var outcomeCeiling: Double { outcome == .hrv ? 400 : 100 }

        /// An absolute outcome value with its unit.
        func format(_ v: Double) -> String { outcome.format(v) }

        /// A signed modelled change with its unit, one decimal at most ("−7 %" / "+1.5 ms").
        func signed(_ v: Double) -> String {
            let rounded = (abs(v) * 10).rounded() / 10
            let sign = rounded == 0 ? "" : (v < 0 ? "\u{2212}" : "+")
            return sign + outcome.format(rounded, fractionDigits: 1)
        }

        // MARK: Copy (whole sentences per behaviour and direction — never stitched fragments)

        /// The honest read of the curve: still typical, contradicting the typical pattern, or yours.
        var readSentence: String {
            let r = response
            let per = signed(r.perUnit)
            let metric = outcome.outcomeName
            if r.priorDominated {
                switch behavior {
                case .alcohol:
                    return String(localized: "Each extra drink typically lines up with about \(per) on \(metric).")
                case .caffeine:
                    return String(localized: "Each later caffeine step typically lines up with about \(per) on \(metric).")
                }
            }
            if r.contradictsPrior {
                return String(localized: "In your data so far, this doesn’t move \(outcome.possessive) the way it typically does (\(r.nUser) days).")
            }
            switch behavior {
            case .alcohol:
                return String(localized: "For you, each extra drink tends to line up with about \(per) on \(metric) (\(r.nUser) days).")
            case .caffeine:
                return String(localized: "For you, each later caffeine step tends to line up with about \(per) on \(metric) (\(r.nUser) days).")
            }
        }

        /// Shown while the estimate is still mostly the population prior.
        var priorBanner: String {
            switch behavior {
            case .alcohol:
                return String(localized: "Based mostly on typical patterns, not yet yours. Log a few more days with alcohol and this becomes yours.")
            case .caffeine:
                return String(localized: "Based mostly on typical patterns, not yet yours. Log a few more days with late caffeine and this becomes yours.")
            }
        }

        var perUnitLabel: String {
            switch behavior {
            case .alcohol:  return String(localized: "Per extra drink")
            case .caffeine: return String(localized: "Per later step")
            }
        }

        var forecastOverline: String {
            switch behavior {
            case .alcohol:  return String(localized: "Tonight\u{2019}s forecast")
            case .caffeine: return String(localized: "Timing forecast")
            }
        }

        /// The what-if read for a previewed dose: where the metric tends to land relative to the
        /// typical starting dose (1), on typical patterns or on the user's own days.
        func forecastSentence(dose: Int, delta: Double) -> String {
            let metric = outcome.outcomeName
            if dose <= 1 {
                switch behavior {
                case .alcohol:
                    return String(localized: "No extra drink tonight: the forecast for \(metric) stays where it is.")
                case .caffeine:
                    return String(localized: "Caffeine by noon: the forecast for \(metric) stays where it is.")
                }
            }
            let mag = outcome.format((abs(delta) * 10).rounded() / 10, fractionDigits: 1)
            let who = outcome.possessive
            let step = stepLabel(dose)
            let lower = delta <= 0
            let n = response.nUser
            switch (behavior, response.priorDominated, lower) {
            case (.alcohol, true, true):
                return String(localized: "With \(step) tonight, \(who) tends to land about \(mag) lower tomorrow (typical patterns).")
            case (.alcohol, true, false):
                return String(localized: "With \(step) tonight, \(who) tends to land about \(mag) higher tomorrow (typical patterns).")
            case (.alcohol, false, true):
                return String(localized: "With \(step) tonight, \(who) tends to land about \(mag) lower tomorrow (based on \(n) of your days).")
            case (.alcohol, false, false):
                return String(localized: "With \(step) tonight, \(who) tends to land about \(mag) higher tomorrow (based on \(n) of your days).")
            case (.caffeine, true, true):
                return String(localized: "With caffeine \(step), \(who) tends to land about \(mag) lower the next morning (typical patterns).")
            case (.caffeine, true, false):
                return String(localized: "With caffeine \(step), \(who) tends to land about \(mag) higher the next morning (typical patterns).")
            case (.caffeine, false, true):
                return String(localized: "With caffeine \(step), \(who) tends to land about \(mag) lower the next morning (based on \(n) of your days).")
            case (.caffeine, false, false):
                return String(localized: "With caffeine \(step), \(who) tends to land about \(mag) higher the next morning (based on \(n) of your days).")
            }
        }

        /// The dose choices the evening stepper offers (0/1/2/3 → 0…maxCurveDose).
        var doseChoices: [Int] { Array(0...DoseResponseEngine.maxCurveDose) }
        func doseChoiceLabel(_ d: Int) -> String {
            switch behavior {
            case .alcohol:  return d >= DoseResponseEngine.maxCurveDose ? "\(d)+" : "\(d)"
            case .caffeine:
                // Timing buckets, not counts.
                switch d {
                case 0: return String(localized: "Early")
                case 1: return String(localized: "Noon")
                case 2: return String(localized: "2pm+")
                default: return String(localized: "Eve")
                }
            }
        }
        /// The chart scrub label for a dose ("Drinks: 2" / the timing bucket).
        func chartDoseLabel(_ d: Int) -> String {
            switch behavior {
            case .alcohol:  return String(localized: "Drinks: \(d)")
            case .caffeine: return doseChoiceLabel(d)
            }
        }
        /// The whole dose phrase for forecast copy: a drink count, or a caffeine timing phrase
        /// that reads after "With caffeine …". Whole-string keys per variant.
        func stepLabel(_ d: Int) -> String {
            switch behavior {
            case .alcohol:
                return d >= DoseResponseEngine.maxCurveDose ? String(localized: "\(d)+ drinks")
                                                            : String(localized: "\(d) drinks")
            case .caffeine:
                switch d {
                case 0: return String(localized: "in the morning")
                case 1: return String(localized: "around noon")
                case 2: return String(localized: "after 2 pm")
                default: return String(localized: "in the evening")
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
@MainActor
private func hubPreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Insights Hub") {
    InsightsHubView()
        .environmentObject(hubPreviewRepo())
        .frame(width: 920, height: 980)
        .preferredColorScheme(.dark)
}
#endif
