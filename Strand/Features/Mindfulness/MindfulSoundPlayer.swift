import Foundation
import AVFoundation
#if os(iOS)
import UIKit
#endif

// MARK: - Breathing / meditation sound

/// What the breathing exercise sounds like. Stored as `zoop.breathe.sound`.
enum BreathSound: String, CaseIterable, Identifiable {
    case singingBowl, softGong, beep, hapticsOnly, off

    var id: String { rawValue }

    static let storageKey = "zoop.breathe.sound"
    static let volumeKey = "zoop.breathe.soundVolume"
    static let droneKey = "zoop.breathe.drone"
    /// The old on/off switch for the beep; read once so existing users keep their choice.
    static let legacyAudioCuesKey = "breathe.audioCues"

    /// The stored choice, falling back to the legacy beep switch, then to off.
    static func resolve(_ raw: String, legacyAudioCues: Bool) -> BreathSound {
        if let s = BreathSound(rawValue: raw) { return s }
        return legacyAudioCues ? .beep : .off
    }

    var playsAudio: Bool { self == .singingBowl || self == .softGong || self == .beep }

    var label: String {
        switch self {
        case .singingBowl: return String(localized: "zoop.breathe.sound.bowl", defaultValue: "Singing bowl", bundle: .main)
        case .softGong: return String(localized: "zoop.breathe.sound.gong", defaultValue: "Soft gong", bundle: .main)
        case .beep: return String(localized: "zoop.breathe.sound.beep", defaultValue: "Beep", bundle: .main)
        case .hapticsOnly: return String(localized: "zoop.breathe.sound.haptics", defaultValue: "Haptics only", bundle: .main)
        case .off: return String(localized: "zoop.breathe.sound.off", defaultValue: "Sounds off", bundle: .main)
        }
    }
}

// MARK: - Player

/// Plays the synthesised bowl, gong and beep cues plus an optional drone through an `AVAudioEngine`.
///
/// Audio session: `.ambient` with mix-with-others, so the silent switch mutes it and music keeps
/// playing. Three cue players take turns so a bowl's long tail rings on under the next one instead of
/// being cut. The engine stops when the app goes to the background and comes back on return if it
/// was wanted; the screen owning the player calls `deactivate()` when it leaves.
@MainActor
final class MindfulSoundPlayer: ObservableObject {

    enum Cue { case inhale, exhale, bell }

    private let engine = AVAudioEngine()
    private let cuePlayers = (0..<3).map { _ in AVAudioPlayerNode() }
    private let dronePlayer = AVAudioPlayerNode()
    private var nextPlayer = 0
    private var active = false
    private var wanted = false
    private var droneWanted = false
    private var attached = false
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private let format = AVAudioFormat(standardFormatWithSampleRate: SingingBowlSynth.sampleRate, channels: 1)

    private(set) var sound: BreathSound = .off
    private var buffers: [String: AVAudioPCMBuffer] = [:]

    init() {
        #if os(iOS)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend() }
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        })
        #endif
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Sets the sound and volume (0-1) and pre-renders the cues off the main thread.
    func configure(sound: BreathSound, volume: Double) {
        self.sound = sound
        engine.mainMixerNode.outputVolume = Float(min(max(volume, 0), 1))
        guard sound.playsAudio else { return }
        prepare(keys(for: sound))
    }

    /// Brings the engine and audio session up. Idempotent.
    func activate() {
        wanted = true
        guard !active, let format else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true, options: [])
        #endif
        if !attached {
            for p in cuePlayers + [dronePlayer] {
                engine.attach(p)
                engine.connect(p, to: engine.mainMixerNode, format: format)
            }
            attached = true
        }
        do {
            try engine.start()
            cuePlayers.forEach { $0.play() }
            active = true
            if droneWanted { startDrone() }
        } catch {
            active = false   // sound is a nicety; haptics and the visual carry the pace
        }
    }

    /// Stops everything and releases the audio session.
    func deactivate() {
        wanted = false
        droneWanted = false
        shutDown()
    }

    func play(_ cue: Cue) {
        guard active, sound.playsAudio || cue == .bell, let buffer = buffers[key(for: cue)] else { return }
        let p = cuePlayers[nextPlayer]
        nextPlayer = (nextPlayer + 1) % cuePlayers.count
        p.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !p.isPlaying { p.play() }
    }

    /// The meditation timer's bell, whatever the breathing sound is set to.
    func prepareBell() { prepare(["bell"]) }

    func setDrone(_ on: Bool) {
        droneWanted = on
        if on { startDrone() } else { dronePlayer.stop() }
    }

    // MARK: Private

    private func startDrone() {
        guard active else { prepare(["drone"]); return }
        guard let buffer = buffers["drone"] else {
            prepare(["drone"]) { [weak self] in if self?.droneWanted == true { self?.startDrone() } }
            return
        }
        dronePlayer.stop()
        dronePlayer.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        dronePlayer.play()
    }

    private func suspend() {
        guard active else { return }
        shutDown()
    }

    private func resume() {
        if wanted { activate() }
    }

    private func shutDown() {
        guard active else { return }
        (cuePlayers + [dronePlayer]).forEach { $0.stop() }
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
        active = false
    }

    private func keys(for sound: BreathSound) -> [String] {
        switch sound {
        case .singingBowl: return ["bowl.in", "bowl.out"]
        case .softGong: return ["gong.in", "gong.out"]
        case .beep: return ["beep.in", "beep.out"]
        case .hapticsOnly, .off: return []
        }
    }

    private func key(for cue: Cue) -> String {
        let prefix: String
        switch sound {
        case .softGong: prefix = "gong"
        case .beep: prefix = "beep"
        default: prefix = "bowl"
        }
        switch cue {
        case .inhale: return prefix + ".in"
        case .exhale: return prefix + ".out"
        case .bell: return "bell"
        }
    }

    nonisolated private static func samples(for key: String) -> [Float] {
        switch key {
        case "bowl.in": return SingingBowlSynth.render(SingingBowlSynth.inhaleBowl)
        case "bowl.out": return SingingBowlSynth.render(SingingBowlSynth.exhaleBowl)
        case "gong.in": return SingingBowlSynth.render(SingingBowlSynth.inhaleGong)
        case "gong.out": return SingingBowlSynth.render(SingingBowlSynth.exhaleGong)
        case "beep.in": return SingingBowlSynth.beep(frequency: 440)
        case "beep.out": return SingingBowlSynth.beep(frequency: 330)
        case "bell": return SingingBowlSynth.render(SingingBowlSynth.timerBell)
        case "drone": return SingingBowlSynth.drone()
        default: return []
        }
    }

    /// Renders any missing cue off the main thread, then wraps it in a PCM buffer here.
    private func prepare(_ keys: [String], then done: (() -> Void)? = nil) {
        let missing = keys.filter { buffers[$0] == nil }
        guard !missing.isEmpty else { done?(); return }
        Task {
            let rendered = await Task.detached(priority: .userInitiated) {
                missing.map { ($0, Self.samples(for: $0)) }
            }.value
            for (key, samples) in rendered { buffers[key] = makeBuffer(samples) }
            done?()
        }
    }

    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            channel.update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
