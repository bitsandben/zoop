import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Live workout mode (#238): the in-exercise screen. One large field and a grid of fields the user picks
/// per sport (`LiveWorkoutLayout`), the km / mile splits for GPS sports, and the controls. Every number
/// comes from `LiveWorkoutReadings`, resolved once per tick from the same live feed and scorers the rest
/// of the app uses: smoothed `AppModel.bpm`, the running `liveStrain`, and the GPS recorder's route.
///
/// The elapsed time appears once, wherever the layout puts it; the bottom bar holds only the controls.
/// Minimizing closes the screen and leaves the session running (the bar above the tab bar brings it back).
struct LiveWorkoutView: View {
    @EnvironmentObject private var model: AppModel
    let onClose: () -> Void

    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    /// Keep the screen awake while recording (#703). Opt-in; the toggle lives in Settings.
    @AppStorage("workoutKeepScreenOn") private var keepScreenOn = false

    @State private var layout: LiveWorkoutLayout?
    @State private var showEditor = false
    @State private var showEndConfirm = false
    @State private var showDeleteConfirm = false
    @State private var splitBanner: String?

    private var distanceSystem: UnitSystem {
        UnitPrefs.resolveDistance(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric, override: distanceSystemRaw)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let workout = model.activeWorkout {
                LiveWorkoutContent(workout: workout, metrics: model.gpsRecorder.metrics,
                                   layout: currentLayout(for: workout), distanceSystem: distanceSystem,
                                   effortScale: UnitPrefs.resolveEffortScale(effortScaleRaw),
                                   onEdit: { showEditor = true }, onSplit: announce)
            } else {
                Spacer()
            }
            controls
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        // Above the controls, clear of the large field, so the banner never covers a number.
        .overlay(alignment: .bottom) {
            if let splitBanner {
                LiveWorkoutSplitBanner(text: splitBanner).padding(.bottom, 120)
            }
        }
        .onChangeCompat(of: model.activeWorkout == nil) { gone in if gone { onClose() } }
        // Arm the realtime HR stream while this screen is up (#681); ref-counted in AppModel.
        .onAppear {
            model.startRealtimeHR()
            if keepScreenOn { ScreenIdle.keepAwake(true) }
        }
        .onDisappear {
            model.stopRealtimeHR()
            ScreenIdle.keepAwake(false)
        }
        .sheet(isPresented: $showEditor) {
            if let workout = model.activeWorkout {
                LiveFieldsEditor(sport: workout.sport, gps: model.activeWorkoutIsGps,
                                 layout: Binding(get: { currentLayout(for: workout) }, set: { layout = $0 }))
            }
        }
        // Ending needs an explicit confirm (#517) so a stray tap cannot end the recording.
        .alert("End this workout?", isPresented: $showEndConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("End", role: .destructive) {
                model.endWorkout()
                onClose()
            }
        } message: {
            Text("This stops recording and saves what's captured so far. It can't be resumed.")
        }
    }

    private func currentLayout(for workout: AppModel.ActiveWorkout) -> LiveWorkoutLayout {
        layout ?? LiveWorkoutLayout.load(sport: workout.sport, gps: model.activeWorkoutIsGps)
    }

    /// A finished split: one haptic and a short banner, also read by VoiceOver.
    private func announce(_ text: String) {
        StrandHaptic.success.play()
        #if os(iOS)
        UIAccessibility.post(notification: .announcement, argument: text)
        #endif
        withAnimation(ZoopMotion.card) { splitBanner = text }
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if splitBanner == text { withAnimation(ZoopMotion.card) { splitBanner = nil } }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: ZoopSpacing.m) {
            circleButton("chevron.down", label: LiveWorkoutStrings.minimize) { onClose() }
            Spacer(minLength: 0)
            if let workout = model.activeWorkout {
                VStack(spacing: 2) {
                    HStack(spacing: ZoopSpacing.s) {
                        WorkoutTypeIcon(workoutType: workout.sport, size: 16, weight: .semibold,
                                        color: StrandPalette.textPrimary)
                        Text(WorkoutSource.displaySport(workout.sport))
                            .font(ZoopType.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                    }
                    Text(workout.isPaused ? LiveWorkoutStrings.paused : LiveWorkoutStrings.recording)
                        .font(ZoopType.caption)
                        .foregroundStyle(workout.isPaused ? StrandPalette.statusWarning : StrandPalette.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
            circleButton("slider.horizontal.3", label: LiveWorkoutStrings.customize) { showEditor = true }
        }
        .padding(.horizontal, ZoopSpacing.gutter)
        .padding(.top, ZoopSpacing.s)
        .padding(.bottom, ZoopSpacing.s)
    }

    private func circleButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(ZoopType.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(StrandPalette.surfaceRaised))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    // MARK: Controls

    /// Discard · pause / resume · end. No clock here: the time is a field above.
    private var controls: some View {
        let paused = model.activeWorkout?.isPaused == true
        return HStack(spacing: ZoopSpacing.l) {
            controlButton("trash", tint: StrandPalette.statusCritical, size: 56) { showDeleteConfirm = true }
                .accessibilityLabel(Text("Delete"))
                // An alert, not a confirmation dialog: inside the full-screen cover the dialog never appeared.
                .alert(Text(LiveWorkoutStrings.deleteTitle), isPresented: $showDeleteConfirm) {
                    Button("Cancel", role: .cancel) { }
                    Button("Delete", role: .destructive) {
                        model.discardWorkout()
                        onClose()
                    }
                } message: {
                    Text(LiveWorkoutStrings.deleteMessage)
                }
            controlButton(paused ? "play.fill" : "pause.fill", tint: StrandPalette.primaryButtonText,
                          fill: StrandPalette.primaryButtonFill, size: 76) { model.toggleWorkoutPause() }
                .accessibilityLabel(Text(paused ? "Resume" : "Pause"))
            controlButton("stop.fill", tint: StrandPalette.textPrimary, size: 56) { showEndConfirm = true }
                .accessibilityLabel(Text("End workout"))
                .accessibilityHint(Text("Stops recording and saves what's captured so far"))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, ZoopSpacing.m)
        .padding(.bottom, ZoopSpacing.l)
    }

    private func controlButton(_ icon: String, tint: Color, fill: Color = StrandPalette.surfaceRaised,
                               size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(ZoopType.headline)
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(fill))
                .contentShape(Circle())
        }
        .buttonStyle(LiquidPressStyle())
    }
}

// MARK: - Content (ticks once a second)

/// The scrolling fields. Observes the route metrics itself, so a GPS fix redraws this, not the header.
private struct LiveWorkoutContent: View {
    @EnvironmentObject private var model: AppModel
    let workout: AppModel.ActiveWorkout
    @ObservedObject var metrics: LiveRouteMetrics
    let layout: LiveWorkoutLayout
    let distanceSystem: UnitSystem
    let effortScale: EffortScale
    let onEdit: () -> Void
    let onSplit: (String) -> Void

    @State private var announcedSplits: Int?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let r = readings(at: context.date)
            ScrollView {
                VStack(alignment: .leading, spacing: ZoopSpacing.cardGap) {
                    LiveWorkoutPrimary(field: layout.primary, reading: r.reading(layout.primary))
                        .onLongPressGesture(perform: onEdit)
                    TileGrid {
                        ForEach(layout.gridFields) { LiveWorkoutTile(field: $0, reading: r.reading($0)) }
                    }
                    .onLongPressGesture(perform: onEdit)
                    if r.gps != .off { LiveWorkoutGPSNote(state: r.gps) }
                    if layout.showsSplits && r.gps != .off { LiveWorkoutSplitList(readings: r) }
                    LiveWorkoutSensorRow(distanceSystem: distanceSystem)
                }
                .padding(.horizontal, ZoopSpacing.gutter)
                .padding(.bottom, ZoopSpacing.l)
            }
            #if os(iOS)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
            .onAppear { if announcedSplits == nil { announcedSplits = r.splits.count } }
            .onChangeCompat(of: r.splits.count) { count in announceIfNew(count, readings: r) }
        }
    }

    private func readings(at date: Date) -> LiveWorkoutReadings {
        LiveWorkoutReadings(elapsed: workout.elapsed(at: date), bpm: model.bpm, workout: workout,
                            zoneSet: model.profile.hrZoneSet, effortScale: effortScale,
                            calories: model.liveWorkoutCalories(workout), samples: metrics.samples,
                            elevationGainM: metrics.elevationGainM, distanceSystem: distanceSystem,
                            gps: model.liveGPSState)
    }

    /// Announce each newly completed split once; the first value seen (screen opened mid-run) is not news.
    private func announceIfNew(_ count: Int, readings r: LiveWorkoutReadings) {
        defer { announcedSplits = count }
        guard let previous = announcedSplits, count > previous, let split = r.splits.last else { return }
        onSplit(r.splitTitle(split.index) + " · " + r.paceText(split.seconds))
    }
}
