#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Home detected-workout sheet
//
// The unsaved auto-detected workout in Home's "Today's activities", and the "Workout detected"
// notification, both open this sheet: the window, its heart rate, and the two answers. Nothing is saved
// until Save is tapped; "Not a workout" records the dismissal so the same window never comes back.

/// One detected workout, as the item a Home sheet is presented for.
struct HomeDetectedTarget: Identifiable {
    let workout: DetectedWorkout
    var id: String { "\(workout.startSec):\(workout.endSec)" }
}

struct HomeDetectedWorkoutSheet: View {
    let workout: DetectedWorkout
    /// Called after Save or "Not a workout" has been handled, so Home can drop the row.
    let onHandled: () -> Void
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var heartRate: [Double] = []
    @State private var saving = false

    private var start: Date { Date(timeIntervalSince1970: TimeInterval(workout.startSec)) }
    private var end: Date { Date(timeIntervalSince1970: TimeInterval(workout.endSec)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZoopMetrics.space4) {
                    header
                    statsRow
                    heartRateCard
                    VStack(spacing: ZoopMetrics.space3) {
                        ZoopButton("Save", systemImage: "checkmark", kind: .primary, fullWidth: true) { save() }
                            .disabled(saving)
                        ZoopButton("Not a workout", kind: .secondary, fullWidth: true) { reject() }
                            .disabled(saving)
                    }
                    .padding(.top, ZoopMetrics.space2)
                }
                .padding(.horizontal, ZoopMetrics.screenHPadding)
                .padding(.vertical, ZoopMetrics.space4)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("Workout detected")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(StrandPalette.accent)
                }
            }
        }
        .noopSheetPresentation(largeFirst: false)
        .task(id: workout.startSec) {
            heartRate = await repo.workoutHrBuckets(from: workout.startSec, to: workout.endSec).map(\.bpm)
        }
    }

    private var header: some View {
        HStack(spacing: ZoopMetrics.space3) {
            Image(systemName: "figure.run")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(StrandPalette.surfaceBase)
                .frame(width: 48, height: 40)
                .background(SquircleShape().fill(StrandPalette.effortColor))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))")
                    .font(StrandFont.rounded(22, weight: .bold).monospacedDigit())
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(start.formatted(date: .complete, time: .omitted))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: ZoopMetrics.space3) {
            stat("Duration", String(localized: "\(workout.durationMin) min"))
            stat("Avg HR", "\(workout.avgBpm)")
            stat("Peak HR", "\(workout.peakBpm)")
        }
    }

    @ViewBuilder
    private var heartRateCard: some View {
        if heartRate.count >= 2 {
            VStack(alignment: .leading, spacing: ZoopMetrics.space3) {
                Text("Heart rate")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                LiquidThread(bpm: heartRate, tint: StrandPalette.liquidHeart, height: 92, animated: false)
            }
            .padding(ZoopMetrics.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ZoopPanelSurface())
        }
    }

    private func stat(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(StrandFont.rounded(20, weight: .bold).monospacedDigit())
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(ZoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZoopPanelSurface())
    }

    private func save() {
        saving = true
        Task {
            _ = await repo.saveDetectedWorkout(workout)
            onHandled()
            dismiss()
            await repo.refresh()
        }
    }

    private func reject() {
        repo.dismissDetectedSuggestion(workout)
        onHandled()
        dismiss()
    }
}
#endif
