import Foundation

// Turns a breathing pace into a deterministic inhale/exhale haptic cue list that can be felt with the
// screen off. Pure: the BLE layer maps each `BreathCue` onto the strap's haptic command
// (`AppModel.buzz(loops:)`) and schedules the gaps with the `HapticClock` walk.
// Felt language matches the Breathe screen: inhale onset = one pulse, exhale onset = two. Each strap
// buzz is a fixed-length motor pulse, so a cue is only "fire N loops at offset T". A cycle lasts
// 60000/bpm ms, split by `inhaleFraction` (the calming ~0.4:0.6 ratio of the Relax preset).

/// Which phase of the breath a cue marks. The on-screen orb follows the same phase clock; screen-off, the buzz is the whole cue.
public enum BreathPhase: String, Equatable, Sendable {
    /// The start of an inhale: a single light pulse.
    case inhale
    /// A breath hold (full or empty): no buzz by default.
    case hold
    /// The start of an exhale: a heavier two-pulse cue.
    case exhale
    /// Instruction-only beat (e.g. nostril side): no buzz.
    case textOnly
}

/// One element of a paced-breathing schedule: fire `loops` buzz loops at `offsetMs` from session start,
/// marking the onset of `phase`.
public struct BreathCue: Equatable, Sendable {
    /// Milliseconds from session start at which to fire this cue.
    public let offsetMs: Int
    /// The breath phase this cue marks (inhale light, exhale heavy, hold/textOnly silent).
    public let phase: BreathPhase
    /// Buzz loops to play: 1 inhale, 2 exhale, 0 silent.
    public let loops: Int
    /// Optional UI label for `textOnly` / nostril cues (English source; localize in the view).
    public let label: String?

    public init(offsetMs: Int, phase: BreathPhase, loops: Int, label: String? = nil) {
        self.offsetMs = offsetMs
        self.phase = phase
        self.loops = loops
        self.label = label
    }
}

public enum BreathPacer {

    // MARK: - Tunables (Breathe parity)

    /// Loops for an inhale onset: one light pulse, as Breathe fires.
    public static let inhaleLoops: Int = 1
    /// Loops for an exhale onset: two pulses, as Breathe fires.
    public static let exhaleLoops: Int = 2
    /// Default inhale fraction: the calming ~40:60 long-exhale ratio of the Relax preset.
    public static let defaultInhaleFraction: Double = 0.4
    /// Slowest / fastest paces scheduled (resonance sweep band, 4.5-7 br/min); out-of-range `bpm` is clamped.
    public static let minBpm: Double = 3.0
    public static let maxBpm: Double = 12.0

    // MARK: - Pacer

    /// Cue list for `cycles` breaths at `bpm`: one inhale and one exhale cue per cycle, in time order.
    /// Pure: identical inputs give an identical list. `bpm` is clamped to [minBpm, maxBpm] and
    /// `inhaleFraction` to 0.1...0.9 so each phase has some duration. `cycles` below 1 yields an empty schedule.
    public static func schedule(bpm: Double,
                                inhaleFraction: Double = defaultInhaleFraction,
                                cycles: Int) -> [BreathCue] {
        guard cycles >= 1 else { return [] }
        let safeBpm = min(max(bpm, minBpm), maxBpm)
        let frac = min(max(inhaleFraction, 0.1), 0.9)

        // Integer ms so offsets are exact and platform-identical.
        let cycleMs = Int((60_000.0 / safeBpm).rounded())
        let inhaleMs = Int((Double(cycleMs) * frac).rounded())

        var out: [BreathCue] = []
        out.reserveCapacity(cycles * 2)
        for c in 0..<cycles {
            let base = c * cycleMs
            out.append(BreathCue(offsetMs: base, phase: .inhale, loops: inhaleLoops))
            out.append(BreathCue(offsetMs: base + inhaleMs, phase: .exhale, loops: exhaleLoops))
        }
        return out
    }

    /// Total scheduled duration (ms) of `cycles` whole cycles at `bpm`.
    public static func sessionDurationMs(bpm: Double, cycles: Int) -> Int {
        guard cycles >= 1 else { return 0 }
        let safeBpm = min(max(bpm, minBpm), maxBpm)
        let cycleMs = Int((60_000.0 / safeBpm).rounded())
        return cycleMs * cycles
    }
}
