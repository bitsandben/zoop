import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Meditation timer
//
// A silent sit with a synthesised singing bowl at the start and end (and optionally every 5 minutes),
// plus an optional quiet drone. A finished or stopped sit of a minute or more is recorded in
// `MindfulSessionLog`, so it counts on the Training page and its heart-rate response is measured.

struct MeditationTimerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var sound = MindfulSoundPlayer()

    @AppStorage("zoop.meditation.minutes") private var minutes = 10
    @AppStorage("zoop.meditation.intervalBells") private var intervalBells = false
    @AppStorage(BreathSound.droneKey) private var drone = false
    @AppStorage(BreathSound.volumeKey) private var volume = 0.7

    @State private var startedAt: Date?
    @State private var lastBellMinute = 0
    @State private var finished = false
    @State private var now = Date()

    private static let options = [5, 10, 15, 20, 30]
    private static let intervalMinutes = 5
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: ZoopSpacing.xl) {
                Spacer(minLength: 0)
                clock
                Spacer(minLength: 0)
                if startedAt == nil { setup }
                control
            }
            .padding(ZoopSpacing.gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(Text(MeditationStrings.title))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { finish(record: true); dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(Text(MeditationStrings.close))
                }
            }
        }
        .onAppear {
            sound.configure(sound: .off, volume: volume)
            sound.prepareBell()
            sound.activate()
        }
        .onDisappear { finish(record: true); sound.deactivate() }
        .onReceive(tick) { t in now = t; step(t) }
        .onChangeCompat(of: drone) { on in if startedAt != nil { sound.setDrone(on) } }
    }

    // MARK: Parts

    private var remaining: Int {
        guard let startedAt else { return minutes * 60 }
        return max(0, minutes * 60 - Int(now.timeIntervalSince(startedAt)))
    }

    private var clock: some View {
        VStack(spacing: ZoopSpacing.s) {
            Text(Duration.seconds(remaining).formatted(.time(pattern: .minuteSecond)))
                .font(ZoopType.display)
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
                .contentTransition(.numericText(countsDown: true))
            Text(finished ? MeditationStrings.done : (startedAt == nil ? MeditationStrings.ready : MeditationStrings.sitting))
                .font(ZoopType.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.m) {
            Picker(selection: $minutes) {
                ForEach(Self.options, id: \.self) { m in
                    Text(Duration.seconds(m * 60).formatted(.units(allowed: [.minutes], width: .abbreviated))).tag(m)
                }
            } label: { Text(MeditationStrings.length) }
            .pickerStyle(.segmented)
            ListCard {
                Toggle(isOn: $intervalBells) { Text(MeditationStrings.intervalBells) }
                    .tint(StrandPalette.accent).listCardRow(isFirst: true)
                Toggle(isOn: $drone) { Text(MeditationStrings.drone) }
                    .tint(StrandPalette.accent).listCardRow()
                HStack(spacing: ZoopSpacing.m) {
                    Image(systemName: "speaker.fill").foregroundStyle(StrandPalette.textTertiary).accessibilityHidden(true)
                    Slider(value: $volume, in: 0...1) { Text(MeditationStrings.volume) }
                        .tint(StrandPalette.accent)
                        .onChangeCompat(of: volume) { v in sound.configure(sound: .off, volume: v) }
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(StrandPalette.textTertiary).accessibilityHidden(true)
                }
                .listCardRow()
            }
            .font(ZoopType.body)
            .foregroundStyle(StrandPalette.textPrimary)
        }
    }

    @ViewBuilder private var control: some View {
        if startedAt == nil {
            Button { begin() } label: { Label { Text(MeditationStrings.start) } icon: { Image(systemName: "play.fill") } }
                .buttonStyle(ZoopButtonStyle(.primary, fullWidth: true))
        } else {
            Button { finish(record: true); dismiss() } label: { Text(MeditationStrings.end) }
                .buttonStyle(ZoopButtonStyle(.secondary, fullWidth: true))
        }
    }

    // MARK: Session

    private func begin() {
        now = Date()
        startedAt = now
        finished = false
        lastBellMinute = 0
        ScreenIdle.keepAwake(true)
        sound.activate()
        sound.play(.bell)
        if drone { sound.setDrone(true) }
    }

    private func step(_ now: Date) {
        guard let startedAt, !finished else { return }
        let elapsed = Int(now.timeIntervalSince(startedAt))
        if elapsed >= minutes * 60 {
            sound.play(.bell)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { sound.play(.bell) }
            finish(record: true)
            finished = true
            return
        }
        let minute = elapsed / 60
        if intervalBells, minute > lastBellMinute, minute % Self.intervalMinutes == 0 {
            lastBellMinute = minute
            sound.play(.bell)
        }
    }

    /// Records the sit (once) and releases keep-awake and the drone. The bell tail keeps ringing.
    private func finish(record: Bool) {
        guard let start = startedAt, !finished else { return }
        if record {
            let end = min(Date(), start.addingTimeInterval(TimeInterval(minutes * 60)))
            MindfulSessionLog.record(kind: .meditation, start: start, end: end)
        }
        finished = true
        sound.setDrone(false)
        ScreenIdle.keepAwake(false)
    }
}

extension View {
    /// The meditation timer, full screen on iPhone and as a sheet on the Mac.
    func meditationCover(isPresented: Binding<Bool>) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented) { MeditationTimerView() }
        #else
        sheet(isPresented: isPresented) { MeditationTimerView() }
        #endif
    }
}

enum MeditationStrings {
    static let title = LocalizedStringResource("zoop.meditation.title", defaultValue: "Meditation", bundle: .main)
    static let close = LocalizedStringResource("zoop.meditation.close", defaultValue: "Close", bundle: .main)
    static let ready = LocalizedStringResource("zoop.meditation.ready", defaultValue: "Sit comfortably and let your breath settle.", bundle: .main)
    static let sitting = LocalizedStringResource("zoop.meditation.sitting", defaultValue: "Notice your breath; when your mind wanders, come back.", bundle: .main)
    static let done = LocalizedStringResource("zoop.meditation.done", defaultValue: "Well done. The session is saved.", bundle: .main)
    static let length = LocalizedStringResource("zoop.meditation.length", defaultValue: "Length", bundle: .main)
    static let intervalBells = LocalizedStringResource("zoop.meditation.intervalBells", defaultValue: "Bell every 5 minutes", bundle: .main)
    static let drone = LocalizedStringResource("zoop.meditation.drone", defaultValue: "Soft drone", bundle: .main)
    static let volume = LocalizedStringResource("zoop.meditation.volume", defaultValue: "Volume", bundle: .main)
    static let start = LocalizedStringResource("zoop.meditation.start", defaultValue: "Start", bundle: .main)
    static let end = LocalizedStringResource("zoop.meditation.end", defaultValue: "End", bundle: .main)
}
