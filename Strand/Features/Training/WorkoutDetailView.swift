import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Workout detail (#410)
//
// A read-only drill-down for one session: who and when, its Effort with the full metric anatomy, the
// numbers of the session, the heart-rate curve, the zone split, what the body did afterwards, and the
// GPS route when one was recorded on-device.
//
// The Training page pushes it onto its navigation stack. Today's feed still presents it in a sheet
// (`presentation == .sheet`), which adds a Done button; the content is the same either way.
// The sections live in the `WorkoutDetail*` files of this folder.

struct WorkoutDetailView: View {

    enum Presentation { case sheet, pushed }

    let row: WorkoutRow
    var presentation: Presentation = .sheet

    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @StateObject var model: WorkoutDetailModel

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue

    /// The readout whose explainer sheet is open.
    @State private var explained: MetricReadout?

    init(row: WorkoutRow, presentation: Presentation = .sheet) {
        self.row = row
        self.presentation = presentation
        _model = StateObject(wrappedValue: WorkoutDetailModel(row: row))
    }

    var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    var format: TrainingFormat {
        let system = UnitSystem(rawValue: unitSystemRaw) ?? .metric
        return TrainingFormat(distanceSystem: UnitPrefs.resolveDistance(system: system, override: distanceSystemRaw))
    }

    var body: some View {
        ScreenScaffold(title: "\(WorkoutSource.displaySport(row.sport))", lazy: true) {
            headerCard
            tiles
            heartRateCard
            zonesCard
            afterWorkoutCard
            routeCard
        }
        .toolbar {
            if presentation == .sheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await model.load(repo: repo, profile: profile) }
        .sheet(item: $explained) { readout in
            MetricExplainerSheet(readout, explanation: model.effortExplanation(scale: effortScale))
        }
    }

    // MARK: Header

    /// Sport and time, then the Effort as the screen's hero number. Tapping the hero opens its explainer.
    var headerCard: some View {
        HeroCard {
            HStack(spacing: ZoopSpacing.m) {
                Image(systemName: sportSymbol(row.sport))
                    .font(ZoopType.headline)
                    .foregroundStyle(StrandPalette.effortColor)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: ZoopRadius.button, style: .continuous)
                        .fill(StrandPalette.effortColor.opacity(0.14)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(format.longDate(row.startTs))
                        .font(ZoopType.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("\(format.timeRange(start: row.startTs, end: row.endTs)) \u{00B7} \(sourceName)")
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: 0)
            }
            let effort = model.effortReadout(scale: effortScale)
            Button { explained = effort } label: { MetricHero(effort) }
                .buttonStyle(.plain)
        }
    }

    /// Where the session came from, as plain text: it decides which edits exist, not how it looks.
    private var sourceName: String {
        switch WorkoutSource.classify(row.source) {
        case .whoop: return String(localized: "Whoop")
        case .apple: return String(localized: "Apple")
        case .detected: return String(localized: "Detected")
        case .manual: return String(localized: "Manual")
        case .lifting: return String(localized: "Lifting")
        case .activityFile: return String(localized: "File")
        }
    }
}

#if DEBUG
#Preview("Workout Detail") {
    NavigationStack {
        WorkoutDetailView(row: WorkoutRow(
            startTs: Int(Date().timeIntervalSince1970) - 3600,
            endTs: Int(Date().timeIntervalSince1970),
            sport: "Running", source: "whoop", durationS: 3600, energyKcal: 712,
            avgHr: 152, maxHr: 178, strain: 62, distanceM: 10_400,
            zonesJSON: #"{"z1":12.5,"z2":28.0,"z3":33.5,"z4":18.0,"z5":6.0}"#, notes: nil, steps: nil),
            presentation: .pushed)
            .environmentObject(Repository(deviceId: "preview"))
            .environmentObject(ProfileStore())
    }
    .preferredColorScheme(.dark)
}
#endif
