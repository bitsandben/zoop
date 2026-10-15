#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

/// The cards of one day, top to bottom. At most seven on a regular day; the check-in, the moment and
/// the cycle only appear when they have something to say.
struct TodayContentStack: View {
    struct Actions {
        let explain: (MetricReadout) -> Void
        let openActivity: (TodayActivity) -> Void
        let editNap: (TodayActivity) -> Void
        let startCheckIn: () -> Void
        let dismissCheckIn: () -> Void
        let answerCheckIn: () -> Void
        let quickActions: () -> Void
    }

    let content: TodayContent
    let actions: Actions

    var body: some View {
        if let greeting = content.greeting {
            Text(greeting)
                .font(ZoopType.title)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
        }
        if content.isToday { HealthAlertBanner() }

        TodayRingsView(content: content, onExplain: actions.explain)
        if content.isToday { CoachTodayCard() } // Coach card mounts here

        TileGrid {
            TodayLinkedTile(route: .health, readout: nil, onExplain: actions.explain) {
                TodayHealthTile(summary: content.health)
            }
            TodayLinkedTile(route: .stress, readout: content.stress, onExplain: actions.explain) {
                MetricTile(content.stress)
            }
        }

        if let energy = content.energy {
            TodayLinkedTile(route: .energyBank, readout: energy, onExplain: actions.explain) {
                MetricTile(energy)
            }
        }

        TodayCheckInCard(state: content.checkIn, onStart: actions.startCheckIn,
                         onDismiss: actions.dismissCheckIn, onAnswer: actions.answerCheckIn)

        sectionTitle(TodayCopy.myDay, id: "myDay") {
            Button(action: actions.quickActions) {
                Image(systemName: "plus")
                    .font(ZoopType.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(TodayCopy.quickActions))
        }
        TodayMyDayCard(moment: content.moment, activities: content.activities,
                       onOpen: actions.openActivity, onEditNap: actions.editNap)
        if content.isToday { ActiveWorkoutIndicatorSection(showStart: false) }
        if content.isToday { TodayFastingCard() }
        if content.showsCycle { HomeCycleCard() }

        sectionTitle(TodayCopy.dashboard, id: "dashboard") { EmptyView() }
        TodayDashboardCard(readouts: content.dashboard, onExplain: actions.explain)

        TodayLinkedTile(route: .fitnessAge, readout: content.fitnessAge, onExplain: actions.explain) {
            MetricTile(content.fitnessAge)
        }
    }

    /// `id` is the scroll anchor the DEBUG screenshot hook in `TodayScreen` jumps to.
    private func sectionTitle<Trailing: View>(_ title: LocalizedStringResource, id: String,
                                              @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title)
                .font(ZoopType.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: ZoopSpacing.s)
            trailing()
        }
        .frame(minHeight: 44)
        .padding(.top, ZoopSpacing.m)
        .id(id)
    }
}

/// Everything Today presents as a sheet.
enum TodaySheet: Identifiable {
    case settings
    case checkIn
    case workout(WorkoutRow)
    case nap(CachedSleepSession)
    case napEdit(CachedSleepSession)
    case detected(DetectedWorkout)

    var id: String {
        switch self {
        case .settings: return "settings"
        case .checkIn: return "checkIn"
        case .workout(let w): return "workout-\(w.startTs)"
        case .nap(let n): return "nap-\(n.startTs)"
        case .napEdit(let n): return "napEdit-\(n.startTs)"
        case .detected(let d): return "detected-\(d.startSec)"
        }
    }
}

struct TodaySheetContent: View {
    let sheet: TodaySheet
    let onDetectedHandled: () -> Void
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch sheet {
        case .settings:
            NavigationStack {
                SettingsView()
                    .background(StrandPalette.surfaceBase.ignoresSafeArea())
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                    }
            }
            .opaqueSheetBackground()
        case .checkIn:
            MorningCheckInSheet()
                .presentationDetents([.medium, .large])
                .opaqueSheetBackground()
                .presentationDragIndicator(.visible)
        case .workout(let row):
            NavigationStack { WorkoutDetailView(row: row).environmentObject(repo) }
                .noopSheetPresentation(largeFirst: true)
        case .nap(let nap):
            HomeNapDetailSheet(nap: nap).opaqueSheetBackground()
        case .napEdit(let nap):
            HomeNapTimeEditor(nap: nap).opaqueSheetBackground()
        case .detected(let workout):
            HomeDetectedWorkoutSheet(workout: workout, onHandled: onDetectedHandled).opaqueSheetBackground()
        }
    }
}
#endif
