import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Active-workout-in-progress indicator (Today)
//
// A "workout in progress" card the Today dashboard shows whenever a manual workout is active. Tapping it
// routes to the Live surface and opens the in-exercise screen (via NavRouter.openActiveWorkout()). Detection
// reads the single source of truth, `AppModel.activeWorkout`, which already survives an app kill (it's
// rehydrated from the durable snapshot on launch), so the card auto-appears and auto-clears with no new
// lifecycle wiring.

/// The Today indicator's value-typed view model: just the sport label + the workout's start, derived from
/// `AppModel.ActiveWorkout`. Equatable so the leaf below only re-renders when one of these actually changes,
/// and the elapsed clock is formatted from a pure function the tests pin.
struct ActiveWorkoutIndicatorModel: Equatable {
    let sport: String
    let startedAt: Date
    /// The pause state has to be CARRIED, not just consulted: this value type is what the card renders
    /// from, so without these two fields the indicator cannot subtract the paused time or say it is
    /// paused, however correct `AppModel` is. That is precisely how it kept counting through #1533.
    var pausedAt: Date? = nil
    var pausedDuration: TimeInterval = 0

    var isPaused: Bool { pausedAt != nil }

    static func make(from workout: AppModel.ActiveWorkout?) -> ActiveWorkoutIndicatorModel? {
        guard let workout else { return nil }
        return ActiveWorkoutIndicatorModel(sport: workout.sport, startedAt: workout.start,
                                           pausedAt: workout.pausedAt,
                                           pausedDuration: workout.pausedDuration)
    }

    /// Elapsed ACTIVE time, formatted M:SS up to an hour and H:MM:SS once an hour has passed (so a
    /// 90-minute session reads "1:30:00", not "90:00"). Clamped at zero so a clock-skew negative reads 0:00.
    /// Pure + injectable `now` for deterministic tests. (StrandFont.bodyNumber already applies tabular figures,
    /// so the call site does NOT add `.monospacedDigit()`.)
    ///
    /// `pausedAt`/`pausedDuration` default to "never paused" so the existing call sites and tests that
    /// predate pause keep their exact meaning; the math itself lives in `ActiveWorkoutClock`.
    static func elapsed(since start: Date, pausedAt: Date? = nil, pausedDuration: TimeInterval = 0,
                        now: Date = Date()) -> String {
        ActiveWorkoutClock.clock(Int(ActiveWorkoutClock.activeElapsed(
            start: start, pausedAt: pausedAt, pausedDuration: pausedDuration, now: now)))
    }
}

struct ActiveWorkoutIndicatorCard: View {
    let model: ActiveWorkoutIndicatorModel
    let onReturn: () -> Void

    var body: some View {
        ZoopCard(tint: StrandPalette.metricRose) {
            VStack(alignment: .leading, spacing: ZoopMetrics.cardInnerSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: ZoopMetrics.space2) {
                    // Decorative "live" dot, hidden from VoiceOver (the card itself reads the full state).
                    Circle()
                        .fill(StrandPalette.metricRose)
                        .frame(width: ZoopMetrics.space2, height: ZoopMetrics.space2)
                        .accessibilityHidden(true)
                    Text("WORKOUT IN PROGRESS")
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.metricRose)
                    // A frozen clock alone is ambiguous with a STALLED one, so say which it is. Reuses the
                    // "Paused" string #1533 already localized rather than minting new copy for a tag.
                    if model.isPaused {
                        Text("Paused")
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer(minLength: ZoopMetrics.space2)
                    // A per-second live clock. The TimelineView re-evaluates ONLY this Text every second, so
                    // the tick never re-renders the rest of the card (let alone TodayView.body). bodyNumber
                    // already carries `.monospacedDigit()`, so no extra modifier here.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(ActiveWorkoutIndicatorModel.elapsed(
                            since: model.startedAt, pausedAt: model.pausedAt,
                            pausedDuration: model.pausedDuration, now: context.date))
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: ZoopMetrics.cardInnerSpacing) {
                        sportLabel
                        Spacer(minLength: ZoopMetrics.space2)
                        ZoopButton("Return to workout", systemImage: "arrow.forward.circle.fill",
                                   kind: .primary, action: onReturn)
                    }

                    VStack(alignment: .leading, spacing: ZoopMetrics.cardInnerSpacing) {
                        sportLabel
                        ZoopButton("Return to workout", systemImage: "arrow.forward.circle.fill",
                                   kind: .primary, fullWidth: true, action: onReturn)
                    }
                }
            }
        }
        // Combine the card into one VoiceOver element so the dot + label + clock + button read as a single
        // "Workout in progress" actionable item rather than five separate stops.
        .accessibilityElement(children: .combine)
    }

    private var sportLabel: some View {
        Text(model.sport)
            .font(StrandFont.headline)
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// Leaf-isolated so an in-progress workout's ~per-sample `AppModel` churn (the elapsed clock tick + the
/// rewritten `activeWorkout`) re-renders ONLY this card, never the whole Today dashboard, the same
/// leaf-isolation pattern the file documents for the live status/sync rows. With `showStart`, today's
/// idle state offers the shared workout picker; past days only show an active-workout indicator.
///
/// Shared by the iOS Today screen and the macOS classic Today, so both draw one leaf. It carries its own
/// `app`/`router` environment objects, so a caller only needs to place `ActiveWorkoutIndicatorSection()`.
struct ActiveWorkoutIndicatorSection: View {
    var showStart = false
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var router: NavRouter

    var body: some View {
        if showStart {
            // Keep this host mounted when a workout starts so its picker and live view survive the update.
            WorkoutStartControl(showsActiveIndicator: true)
        } else if let model = ActiveWorkoutIndicatorModel.make(from: app.activeWorkout) {
            ActiveWorkoutIndicatorCard(model: model) {
                StrandHaptic.selection.play()
                router.openActiveWorkout()
            }
            .transition(.opacity)
        }
    }
}
