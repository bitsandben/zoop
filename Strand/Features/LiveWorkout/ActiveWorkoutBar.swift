import SwiftUI
import StrandDesign

// MARK: - Minimized live workout
//
// The running workout, condensed to one bar above the tab bar on every tab: sport, elapsed time and heart
// rate, each once. Tapping it brings the full live screen back. While the live screen is up it covers
// this bar, so the time is never on screen twice. Mirrors `LiftSessionBar` for gym sessions.

struct ActiveWorkoutBar: View {
    @EnvironmentObject private var model: AppModel
    @State private var showLive = false

    var body: some View {
        if let workout = model.activeWorkout {
            Button { showLive = true } label: {
                HStack(spacing: ZoopSpacing.m) {
                    WorkoutTypeIcon(workoutType: workout.sport, size: 18, weight: .semibold,
                                    color: StrandPalette.effortColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(WorkoutSource.displaySport(workout.sport))
                            .font(ZoopType.body.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                        if workout.isPaused {
                            Text(LiveWorkoutStrings.paused)
                                .font(ZoopType.caption)
                                .foregroundStyle(StrandPalette.statusWarning)
                        }
                    }
                    Spacer(minLength: ZoopSpacing.s)
                    if let bpm = model.bpm {
                        Label { Text(verbatim: "\(bpm)") } icon: { Image(systemName: "heart.fill") }
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.metricRose)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(verbatim: ActiveWorkoutClock.clock(Int(workout.elapsed(at: context.date))))
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    Image(systemName: "chevron.up")
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, ZoopSpacing.l)
                .padding(.vertical, ZoopSpacing.m)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(StrandPalette.hairline, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text(LiveWorkoutStrings.openWorkout))
            .liveWorkoutCover(isPresented: $showLive) {
                LiveWorkoutView(onClose: { showLive = false })
                    .environmentObject(model)
                    .environmentObject(model.live)
            }
        }
    }
}

extension View {
    /// The live session is a full-screen cover on iOS (design system §4.1); macOS has no cover, so a sheet.
    @ViewBuilder
    func liveWorkoutCover<Content: View>(isPresented: Binding<Bool>,
                                         @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #else
        self.sheet(isPresented: isPresented, content: content)
        #endif
    }
}

/// `ActiveWorkoutBar` with the tab-bar clearance, applied only while a workout runs so the shell's bottom
/// inset is unchanged otherwise.
struct ActiveWorkoutBarInset: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.activeWorkout != nil {
            ActiveWorkoutBar()
                .padding(.horizontal, 14)
                .padding(.bottom, ZoopMetrics.tabBarClearance)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
