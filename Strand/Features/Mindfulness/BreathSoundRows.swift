import SwiftUI
import StrandDesign

/// The breathing exercise's sound settings: which cue plays on each phase, how loud, and the optional
/// drone. Sits in the Breathe settings card in place of the old on/off beep switch.
struct BreathSoundRows: View {
    @Binding var sound: BreathSound
    @Binding var volume: Double
    @Binding var drone: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: ZoopSpacing.m) {
                icon(sound.playsAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text(Strings.sound).font(ZoopType.body).foregroundStyle(StrandPalette.textPrimary)
                    Text(Strings.soundDetail).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: ZoopSpacing.s)
                Picker(selection: $sound) {
                    ForEach(BreathSound.allCases) { Text($0.label).tag($0) }
                } label: { Text(Strings.sound) }
                .pickerStyle(.menu)
                .tint(StrandPalette.textSecondary)
            }
            .padding(.vertical, ZoopSpacing.m)
            divider
            HStack(spacing: ZoopSpacing.m) {
                icon("waveform")
                Toggle(isOn: $drone) {
                    Text(Strings.drone).font(ZoopType.body).foregroundStyle(StrandPalette.textPrimary)
                }
                .tint(StrandPalette.accent)
            }
            .padding(.vertical, ZoopSpacing.m)
            if sound.playsAudio || drone {
                divider
                HStack(spacing: ZoopSpacing.m) {
                    icon("speaker.fill")
                    Slider(value: $volume, in: 0...1) { Text(Strings.volume) }
                        .tint(StrandPalette.accent)
                    Image(systemName: "speaker.wave.3.fill")
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, ZoopSpacing.m)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(StrandPalette.hairline).frame(height: 1).padding(.leading, 40)
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(ZoopType.body)
            .foregroundStyle(StrandPalette.textSecondary)
            .frame(width: 28)
            .accessibilityHidden(true)
    }

    private enum Strings {
        static let sound = LocalizedStringResource("zoop.breathe.sound.title", defaultValue: "Sound", bundle: .main)
        static let soundDetail = LocalizedStringResource("zoop.breathe.sound.detail",
                                                         defaultValue: "A cue on each breath · respects silent mode", bundle: .main)
        static let drone = LocalizedStringResource("zoop.breathe.sound.drone", defaultValue: "Soft drone", bundle: .main)
        static let volume = LocalizedStringResource("zoop.breathe.sound.volume", defaultValue: "Volume", bundle: .main)
    }
}
