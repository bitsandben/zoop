import Foundation

// MARK: - Singing-bowl synthesis
//
// Procedural bowl and gong tones, so no audio asset ships or is downloaded. A struck bowl is a handful
// of inharmonic partials (roughly 1, 2.7, 5.1 and 8.2 times the fundamental), each a pair of slightly
// detuned sines that beat slowly against each other, decaying exponentially with the higher partials
// dying first. A gong has a lower fundamental, denser partials and a slower swell. The beep keeps the
// original short sine cue. Everything renders once into mono float samples; the player caches them.

enum SingingBowlSynth {

    struct Partial {
        /// Frequency as a multiple of the fundamental.
        let ratio: Double
        let amplitude: Double
        /// Exponential decay time constant (seconds).
        let decay: Double
        /// Beat rate between the detuned pair (Hz).
        let beat: Double
    }

    struct Voice {
        let fundamental: Double
        let partials: [Partial]
        /// Raised-cosine attack (seconds); a mallet strike is short, a gong swell is long.
        let attack: Double
        let seconds: Double
        let peak: Float
    }

    static let sampleRate: Double = 44_100

    static let bowlPartials = [
        Partial(ratio: 1.00, amplitude: 1.00, decay: 4.5, beat: 0.7),
        Partial(ratio: 2.71, amplitude: 0.45, decay: 2.8, beat: 1.3),
        Partial(ratio: 5.12, amplitude: 0.18, decay: 1.5, beat: 2.1),
        Partial(ratio: 8.21, amplitude: 0.07, decay: 0.8, beat: 3.0),
    ]

    static let gongPartials = [
        Partial(ratio: 1.00, amplitude: 1.00, decay: 5.5, beat: 0.4),
        Partial(ratio: 1.47, amplitude: 0.55, decay: 4.0, beat: 0.6),
        Partial(ratio: 2.09, amplitude: 0.38, decay: 3.0, beat: 0.9),
        Partial(ratio: 2.76, amplitude: 0.24, decay: 2.2, beat: 1.2),
        Partial(ratio: 3.93, amplitude: 0.12, decay: 1.4, beat: 1.7),
        Partial(ratio: 5.31, amplitude: 0.06, decay: 0.9, beat: 2.3),
    ]

    /// Inhale: a brighter bowl (D4). Exhale: a lower, softer one (A3).
    static let inhaleBowl = Voice(fundamental: 293.66, partials: bowlPartials, attack: 0.012, seconds: 6, peak: 0.32)
    static let exhaleBowl = Voice(fundamental: 220.00, partials: bowlPartials, attack: 0.02, seconds: 6, peak: 0.22)
    static let inhaleGong = Voice(fundamental: 146.83, partials: gongPartials, attack: 0.15, seconds: 7, peak: 0.30)
    static let exhaleGong = Voice(fundamental: 110.00, partials: gongPartials, attack: 0.2, seconds: 7, peak: 0.22)
    /// The meditation timer's opening and closing bell: a deeper, longer bowl.
    static let timerBell = Voice(fundamental: 196.00, partials: bowlPartials, attack: 0.01, seconds: 9, peak: 0.34)

    /// Renders one voice. The last 60 ms fade to silence so a cut-off tail never clicks.
    static func render(_ v: Voice) -> [Float] {
        let n = Int(v.seconds * sampleRate)
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        let attackN = max(1, Int(v.attack * sampleRate))
        let releaseN = Int(0.06 * sampleRate)
        var maxAbs: Float = 0
        for (k, p) in v.partials.enumerated() {
            let f = v.fundamental * p.ratio
            let detune = p.beat / 2          // the pair sits at f ± beat/2, so it beats at `beat` Hz
            let w1 = 2 * Double.pi * (f - detune) / sampleRate
            let w2 = 2 * Double.pi * (f + detune) / sampleRate
            let phase = Double(k) * 0.9
            let decayPerSample = exp(-1 / (p.decay * sampleRate))
            var env = p.amplitude
            for i in 0..<n {
                let s = 0.5 * (sin(w1 * Double(i)) + sin(w2 * Double(i) + phase))
                out[i] += Float(s * env)
                env *= decayPerSample
            }
        }
        for i in 0..<n {
            var g: Float = 1
            if i < attackN { g = Float(0.5 - 0.5 * cos(Double.pi * Double(i) / Double(attackN))) }
            if i >= n - releaseN { g *= Float(n - i) / Float(max(releaseN, 1)) }
            out[i] *= g
            maxAbs = max(maxAbs, abs(out[i]))
        }
        guard maxAbs > 0 else { return out }
        let scale = v.peak / maxAbs
        return out.map { $0 * scale }
    }

    /// The original short sine cue, kept as the "Beep" option.
    static func beep(frequency: Double) -> [Float] {
        let n = Int(0.45 * sampleRate)
        let attack = Int(0.02 * sampleRate), release = Int(0.18 * sampleRate)
        return (0..<n).map { i in
            var env: Float = 1
            if i < attack { env = Float(i) / Float(attack) }
            else if i > n - release { env = Float(n - i) / Float(release) }
            return Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate)) * env * 0.28
        }
    }

    /// A quiet, seamless 8-second drone loop: a low fifth and octave with slow swells. Every frequency
    /// completes a whole number of cycles in the loop, so the seam is inaudible.
    static func drone() -> [Float] {
        let seconds = 8.0
        let n = Int(seconds * sampleRate)
        let tones: [(f: Double, a: Double, phase: Double)] = [
            (109.75, 0.40, 0), (110.25, 0.40, 1.3), (165.0, 0.22, 2.1), (220.0, 0.12, 0.7), (330.0, 0.05, 2.9),
        ]
        var out = [Float](repeating: 0, count: n)
        for (k, t) in tones.enumerated() {
            let w = 2 * Double.pi * t.f / sampleRate
            let lfo = 2 * Double.pi / (seconds * sampleRate) * Double(k % 2 == 0 ? 1 : 2)
            for i in 0..<n {
                let swell = 0.7 + 0.3 * sin(lfo * Double(i) + t.phase)
                out[i] += Float(sin(w * Double(i)) * t.a * swell)
            }
        }
        let maxAbs = out.map(abs).max() ?? 1
        return out.map { $0 / max(maxAbs, 0.0001) * 0.10 }
    }
}
