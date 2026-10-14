import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Muscle load card (Zoop, Workouts)
//
// `MuscleLoad` drawn for any training, not only the Lift Log: a "Muscle recovery" card with one
// sentence naming what the week loaded and what it left out, then a two-column grid of the least
// recovered groups (drawn icon, percent recovered, a 10-segment recovery bar). Tapping opens
// `MuscleLoadSheet` with every group's last four weeks and the sessions behind this week's load.

extension MuscleLoad.Group {
    /// Localized name as it reads inside a sentence ("Schultern und Latissimus").
    var displayName: String {
        switch self {
        case .chest: return String(localized: "Chest")
        case .shoulders: return String(localized: "Shoulders")
        case .biceps: return String(localized: "Biceps")
        case .triceps: return String(localized: "Triceps")
        case .forearms: return String(localized: "Forearms")
        case .core: return String(localized: "Abs and core")
        case .upperBack: return String(localized: "Upper back")
        case .lats: return String(localized: "Lats")
        case .lowerBack: return String(localized: "Lower back")
        case .glutes: return String(localized: "Glutes")
        case .quads: return String(localized: "Quads")
        case .hamstrings: return String(localized: "Hamstrings")
        case .calves: return String(localized: "Calves")
        }
    }

    /// The name at the start of a row, first letter capitalised ("Oberer Rücken").
    var rowName: String {
        let n = displayName
        return n.prefix(1).uppercased() + n.dropFirst()
    }
}

extension MuscleLoad.State {
    var label: String {
        switch self {
        case .under: return String(localized: "Little work")
        case .balanced: return String(localized: "Balanced")
        case .high: return String(localized: "High load")
        }
    }

    var color: Color {
        switch self {
        case .under: return StrandPalette.textTertiary
        case .balanced: return StrandPalette.textSecondary
        case .high: return StrandPalette.statusWarning
        }
    }
}

enum MuscleLoadText {
    /// The one-sentence verdict.
    static func verdict(_ v: MuscleLoad.Verdict) -> String {
        switch v {
        case .quietWeek:
            return String(localized: "No training in the last 7 days.")
        case .balanced:
            return String(localized: "This week's load was spread evenly across your muscles.")
        case let .focused(top, sport, low):
            let names = ListFormatter.localizedString(byJoining: top.map(\.displayName))
            let sportName = sport.map { WorkoutSource.displaySport($0) }
            switch (sportName, low) {
            case let (s?, .legs?):
                return String(localized: "\(s) loaded mostly \(names); your legs got little work this week.")
            case let (s?, .upperBody?):
                return String(localized: "\(s) loaded mostly \(names); your upper body got little work this week.")
            case let (s?, .core?):
                return String(localized: "\(s) loaded mostly \(names); your core got little work this week.")
            case let (s?, nil):
                return String(localized: "\(s) loaded mostly \(names) this week.")
            case (nil, .legs?):
                return String(localized: "Most of this week's load went to \(names); your legs got little work.")
            case (nil, .upperBody?):
                return String(localized: "Most of this week's load went to \(names); your upper body got little work.")
            case (nil, .core?):
                return String(localized: "Most of this week's load went to \(names); your core got little work.")
            case (nil, nil):
                return String(localized: "Most of this week's load went to \(names).")
            }
        }
    }
}

// MARK: - Card

extension MuscleLoad.Entry {
    /// Recovery colour: green from 80 %, amber from 50 %, red below; grey when the week left it alone.
    var recoveryColor: Color {
        guard weekLoad > 0 else { return StrandPalette.textTertiary }
        if percentRecovered >= 80 { return StrandPalette.statusPositive }
        if percentRecovered >= 50 { return StrandPalette.statusWarning }
        return StrandPalette.statusCritical
    }
}

struct MuscleLoadCard: View {
    let result: MuscleLoad.Result
    let computedAt: Int

    @State private var showDetail = false

    /// Least recovered first, then the most loaded; eight cells on the card, every group in the sheet.
    private var cells: [MuscleLoad.Entry] {
        Array(result.entries.sorted {
            ($0.percentRecovered, -$0.weekLoad) < ($1.percentRecovered, -$1.weekLoad)
        }.prefix(8))
    }

    var body: some View {
        Button { showDetail = true } label: {
            ZoopCard {
                VStack(alignment: .leading, spacing: ZoopMetrics.space4) {
                    VStack(alignment: .leading, spacing: ZoopMetrics.space1) {
                        HStack(spacing: ZoopMetrics.space2) {
                            Text(String(localized: "muscle.recovery.title", defaultValue: "Muscle recovery"))
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Image(systemName: "arrow.right")
                                .font(StrandFont.footnote.weight(.semibold))
                                .foregroundStyle(StrandPalette.textSecondary)
                            Spacer(minLength: 0)
                        }
                        Text(MuscleLoadText.verdict(result.verdict))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: ZoopMetrics.space4, alignment: .leading),
                                        GridItem(.flexible(), alignment: .leading)],
                              alignment: .leading, spacing: ZoopMetrics.space4) {
                        ForEach(cells, id: \.group) { MuscleRecoveryCell(entry: $0) }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetail) {
            MuscleLoadSheet(result: result, computedAt: computedAt)
        }
    }
}

/// Icon, name, percent recovered and a 10-segment recovery bar.
struct MuscleRecoveryCell: View {
    let entry: MuscleLoad.Entry

    var body: some View {
        HStack(spacing: ZoopMetrics.space3) {
            MuscleIcon(group: entry.group,
                       highlight: entry.weekLoad > 0 ? entry.recoveryColor : StrandPalette.textSecondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.group.rowName)
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(String(localized: "\(entry.percentRecovered)% recovered"))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                RecoverySegments(percent: entry.percentRecovered, color: entry.recoveryColor,
                                 glow: entry.weekLoad > 0)
                    .padding(.top, 3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(entry.group.rowName): \(entry.state.label), \(entry.percentRecovered) percent recovered"))
    }
}

/// Ten rounded pills: filled ones dim, the last filled one bright with a soft glow, the rest dark.
struct RecoverySegments: View {
    let percent: Int
    let color: Color
    var glow = true

    var body: some View {
        let filled = percent <= 0 ? 0 : Swift.max(1, Int((Double(percent) / 10).rounded()))
        HStack(spacing: 2.5) {
            ForEach(0..<10, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(i < filled - 1 ? color.opacity(0.4)
                          : i == filled - 1 ? color : StrandPalette.hairlineStrong)
                    .shadow(color: glow && i == filled - 1 ? color.opacity(0.7) : .clear, radius: 3)
                    .frame(height: 5)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Detail sheet

struct MuscleLoadSheet: View {
    let result: MuscleLoad.Result
    let computedAt: Int

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZoopMetrics.gap) {
                    Text(MuscleLoadText.verdict(result.verdict))
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(sortedEntries, id: \.group) { groupCard($0) }
                    Text("Bars compare each week with the four-week average; the line marks that average.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Estimated from each sport's typical muscle use, duration and intensity.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(ZoopMetrics.screenPadding)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle(Text(String(localized: "muscle.recovery.title", defaultValue: "Muscle recovery")))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #else
        .frame(width: 440, height: 620)
        #endif
    }

    /// Least recovered first, as on the card.
    private var sortedEntries: [MuscleLoad.Entry] {
        result.entries.sorted {
            ($0.percentRecovered, -$0.weekLoad) < ($1.percentRecovered, -$1.weekLoad)
        }
    }

    private func weekLabel(_ index: Int) -> String {
        let weeksBack = MuscleLoad.weeks - 1 - index
        if weeksBack == 0 { return String(localized: "This week") }
        let start = Date(timeIntervalSince1970: TimeInterval(computedAt - (weeksBack + 1) * 7 * 86_400 + 86_400))
        return start.formatted(.dateTime.day().month(.abbreviated))
    }

    private func groupCard(_ e: MuscleLoad.Entry) -> some View {
        let peak = Swift.max(e.weeklyLoads.max() ?? 0, e.weeklyAverage, 1e-9)
        return ZoopCard {
            VStack(alignment: .leading, spacing: ZoopMetrics.space3) {
                HStack(spacing: ZoopMetrics.space3) {
                    MuscleIcon(group: e.group,
                               highlight: e.weekLoad > 0 ? e.recoveryColor : StrandPalette.textSecondary)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: ZoopMetrics.space2) {
                            Text(e.group.rowName)
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer(minLength: ZoopMetrics.space2)
                            Text(e.state.label)
                                .font(StrandFont.caption)
                                .foregroundStyle(e.state.color)
                        }
                        Text(String(localized: "\(e.percentRecovered)% recovered"))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                        RecoverySegments(percent: e.percentRecovered, color: e.recoveryColor, glow: e.weekLoad > 0)
                            .padding(.top, 3)
                    }
                }
                HStack(alignment: .bottom, spacing: ZoopMetrics.space2) {
                    ForEach(Array(e.weeklyLoads.enumerated()), id: \.offset) { i, v in
                        VStack(spacing: ZoopMetrics.space1) {
                            ZStack(alignment: .bottom) {
                                Color.clear
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(i == e.weeklyLoads.count - 1 ? StrandPalette.textPrimary.opacity(0.85)
                                          : StrandPalette.textTertiary.opacity(0.35))
                                    .frame(height: Swift.max(2, 56 * CGFloat(v / peak)))
                            }
                            .frame(height: 56)
                            Text(weekLabel(i))
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .overlay(alignment: .top) {
                    GeometryReader { _ in
                        Rectangle()
                            .fill(StrandPalette.textSecondary)
                            .frame(height: 1)
                            .offset(y: 56 - 56 * CGFloat(e.weeklyAverage / peak))
                    }
                    .frame(height: 56)
                }
                .accessibilityHidden(true)
                if !e.contributions.isEmpty {
                    VStack(spacing: ZoopMetrics.space2) {
                        ForEach(Array(e.contributions.prefix(5).enumerated()), id: \.offset) { _, c in
                            HStack(spacing: ZoopMetrics.space2) {
                                Text(WorkoutSource.displaySport(c.sport))
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                    .lineLimit(1)
                                Text(Date(timeIntervalSince1970: TimeInterval(c.startTs))
                                        .formatted(.dateTime.weekday(.abbreviated).day()))
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                Spacer(minLength: ZoopMetrics.space2)
                                Text(verbatim: "\(Int((100 * c.load / Swift.max(e.weekLoad, 1e-9)).rounded()))%")
                                    .font(StrandFont.captionNumber)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                    }
                }
            }
        }
    }
}
