import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Muscle load card (Zoop, Workouts)
//
// `MuscleLoad` drawn for any training, not only the Lift Log: a flat front/back body map shaded by
// this week's load, one sentence naming what the week loaded and what it left out, and a per-muscle
// list (state, percent recovered, a 10-segment load bar). Tapping opens `MuscleLoadSheet` with each
// group's last four weeks and the sessions behind this week's load.

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

struct MuscleLoadCard: View {
    let result: MuscleLoad.Result
    let computedAt: Int

    @State private var showDetail = false

    /// Groups this week loaded, most first; at most eight rows on the card, all in the sheet.
    private var rows: [MuscleLoad.Entry] {
        Array(result.entries.filter { $0.weekLoad > 0 }.prefix(8))
    }

    var body: some View {
        Button { showDetail = true } label: {
            ZoopCard {
                VStack(alignment: .leading, spacing: ZoopMetrics.space4) {
                    MuscleBodyMap(result: result)
                        .frame(height: 190)
                        .frame(maxWidth: .infinity)
                    Text(MuscleLoadText.verdict(result.verdict))
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !rows.isEmpty {
                        VStack(spacing: ZoopMetrics.space3) {
                            ForEach(rows, id: \.group) { MuscleLoadRow(entry: $0) }
                        }
                    }
                    HStack(spacing: ZoopMetrics.space1) {
                        Text("Estimated from each sport's typical muscle use, duration and intensity.")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                    }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetail) {
            MuscleLoadSheet(result: result, computedAt: computedAt)
        }
    }
}

/// Name, state word, percent recovered, and a 10-segment bar of this week's load share.
struct MuscleLoadRow: View {
    let entry: MuscleLoad.Entry

    var body: some View {
        let filled = MuscleLoad.filledSegments(share: entry.share)
        VStack(alignment: .leading, spacing: ZoopMetrics.space1) {
            HStack(alignment: .firstTextBaseline, spacing: ZoopMetrics.space2) {
                Text(entry.group.rowName)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: ZoopMetrics.space2)
                Text(entry.state.label)
                    .font(StrandFont.caption)
                    .foregroundStyle(entry.state.color)
                    .lineLimit(1)
                Text(String(localized: "\(entry.percentRecovered)% recovered"))
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .frame(minWidth: 92, alignment: .trailing)
            }
            HStack(spacing: 2) {
                ForEach(0..<10, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(i < filled ? MuscleBodyMap.tint(entry) : MuscleBodyMap.neutral)
                        .frame(height: 6)
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(entry.group.rowName): \(entry.state.label), \(entry.percentRecovered) percent recovered"))
    }
}

// MARK: - Body map

/// Stylised front and back figures; each muscle group a rounded region shaded by this week's load.
struct MuscleBodyMap: View {
    let result: MuscleLoad.Result

    /// Unloaded regions, head, hands and feet: one step above the card surface.
    static var neutral: Color { StrandPalette.surfaceOverlay }

    /// One hue, deeper with load: barely-used groups stay faint, the week's most loaded read solid.
    static func tint(_ e: MuscleLoad.Entry?) -> Color {
        guard let e, e.weekLoad > 0 else { return MuscleBodyMap.neutral }
        let t = Swift.min(1, e.share / MuscleLoad.highShare)
        return e.state == .high ? StrandPalette.statusWarning
            : StrandPalette.effortBright.opacity(0.22 + 0.68 * t)
    }

    private enum Part { case ellipse, capsule, rounded(CGFloat) }
    private struct Region {
        let group: MuscleLoad.Group?
        let rect: CGRect
        let part: Part
    }

    private static func pair(_ g: MuscleLoad.Group?, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                             _ part: Part) -> [Region] {
        [Region(group: g, rect: CGRect(x: x, y: y, width: w, height: h), part: part),
         Region(group: g, rect: CGRect(x: 100 - x - w, y: y, width: w, height: h), part: part)]
    }

    /// Shared head, neck, hands and feet in a 100 × 200 frame, plus the torso, pelvis, elbows and knees
    /// underneath so the gaps between regions read as body.
    private static let base: [Region] = [
        Region(group: nil, rect: CGRect(x: 41, y: 2, width: 18, height: 22), part: .ellipse),
        Region(group: nil, rect: CGRect(x: 45, y: 23, width: 10, height: 9), part: .rounded(3)),
        Region(group: nil, rect: CGRect(x: 31, y: 31, width: 38, height: 64), part: .rounded(12)),
        Region(group: nil, rect: CGRect(x: 32, y: 88, width: 36, height: 26), part: .rounded(10)),
    ] + pair(nil, x: 13, y: 70, w: 12, h: 9, .capsule)
      + pair(nil, x: 34.5, y: 139, w: 12, h: 10, .capsule)
      + pair(nil, x: 9, y: 104, w: 9, h: 11, .ellipse)
      + pair(nil, x: 33, y: 186, w: 13, h: 8, .rounded(4))

    private static let front: [Region] = base
        + pair(.shoulders, x: 19, y: 32, w: 17, h: 17, .ellipse)
        + pair(.chest, x: 33, y: 35, w: 16.5, h: 19, .rounded(6))
        + pair(.biceps, x: 15, y: 50, w: 11, h: 25, .capsule)
        + pair(.forearms, x: 10.5, y: 76, w: 10, h: 28, .capsule)
        + [Region(group: .core, rect: CGRect(x: 35, y: 56, width: 30, height: 37), part: .rounded(8))]
        + pair(.quads, x: 32, y: 96, w: 17, h: 48, .rounded(8))
        + pair(.calves, x: 34, y: 147, w: 13, h: 38, .capsule)

    private static let back: [Region] = base
        + pair(.shoulders, x: 19, y: 32, w: 17, h: 17, .ellipse)
        + [Region(group: .upperBack, rect: CGRect(x: 34, y: 33, width: 32, height: 20), part: .rounded(7))]
        + pair(.lats, x: 33, y: 54.5, w: 16, h: 25, .rounded(7))
        + pair(.triceps, x: 15, y: 50, w: 11, h: 25, .capsule)
        + pair(.forearms, x: 10.5, y: 76, w: 10, h: 28, .capsule)
        + [Region(group: .lowerBack, rect: CGRect(x: 36, y: 80.5, width: 28, height: 13), part: .rounded(6))]
        + pair(.glutes, x: 32, y: 95, w: 17, h: 19, .rounded(9))
        + pair(.hamstrings, x: 32, y: 115.5, w: 17, h: 29, .rounded(8))
        + pair(.calves, x: 34, y: 147, w: 13, h: 38, .capsule)

    var body: some View {
        HStack(spacing: ZoopMetrics.space4) {
            figure(Self.front, label: String(localized: "body.front", defaultValue: "Front"))
            figure(Self.back, label: String(localized: "body.back", defaultValue: "Back"))
        }
        .accessibilityHidden(true)
    }

    private func figure(_ regions: [Region], label: String) -> some View {
        VStack(spacing: ZoopMetrics.space1) {
            Canvas { ctx, size in
                let s = Swift.min(size.width / 100, size.height / 200)
                let ox = (size.width - 100 * s) / 2, oy = (size.height - 200 * s) / 2
                for r in regions {
                    let rect = CGRect(x: ox + r.rect.minX * s, y: oy + r.rect.minY * s,
                                      width: r.rect.width * s, height: r.rect.height * s)
                    let path: Path
                    switch r.part {
                    case .ellipse: path = Path(ellipseIn: rect)
                    case .capsule: path = Path(roundedRect: rect, cornerRadius: Swift.min(rect.width, rect.height) / 2)
                    case .rounded(let c): path = Path(roundedRect: rect, cornerRadius: c * s, style: .continuous)
                    }
                    let fill = r.group.map { Self.tint(result.entry($0)) } ?? MuscleBodyMap.neutral
                    ctx.fill(path, with: .color(fill))
                }
            }
            .aspectRatio(0.5, contentMode: .fit)
            Text(label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
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
                    ForEach(result.entries, id: \.group) { groupCard($0) }
                    Text("Bars compare each week with the four-week average; the line marks that average.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(ZoopMetrics.screenPadding)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle(Text("Muscle load"))
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
                HStack(alignment: .firstTextBaseline, spacing: ZoopMetrics.space2) {
                    Text(e.group.rowName)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: ZoopMetrics.space2)
                    Text(e.state.label)
                        .font(StrandFont.caption)
                        .foregroundStyle(e.state.color)
                    Text(String(localized: "\(e.percentRecovered)% recovered"))
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                HStack(alignment: .bottom, spacing: ZoopMetrics.space2) {
                    ForEach(Array(e.weeklyLoads.enumerated()), id: \.offset) { i, v in
                        VStack(spacing: ZoopMetrics.space1) {
                            ZStack(alignment: .bottom) {
                                Color.clear
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(i == e.weeklyLoads.count - 1 ? MuscleBodyMap.tint(e)
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
