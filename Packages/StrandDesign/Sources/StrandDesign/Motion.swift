import SwiftUI

// MARK: - Strand Motion
//
// Physiological motion (breathe / pulse / flow), no cartoon bounce.

public enum StrandMotion {

    // MARK: Spring presets

    /// Interactive spring, snappy, for direct manipulation.
    public static let interactive = Animation.interactiveSpring(response: 0.28, dampingFraction: 0.82, blendDuration: 0.1)

    /// Gentle spring: the house style for value changes (ring draw-in, gauges).
    public static let gentle = Animation.spring(response: 0.5, dampingFraction: 0.8)

    /// A slower spring for hero transitions.
    public static let hero = Animation.spring(response: 0.85, dampingFraction: 0.85)

    // MARK: Durations

    public static let durationStandard: Double = 0.30

    public static let durationSlow: Double = 0.9

    /// One breath cycle for ambient pulsing.
    public static let breathPeriod: Double = 3.2

    // MARK: Curves

    public static let drawIn = Animation.easeOut(duration: durationSlow)

    /// The ring/gauge draw-in, or `nil` under Reduce Motion so `withAnimation` snaps to the final frame.
    public static func drawIn(reduced: Bool) -> Animation? {
        reduced ? nil : drawIn
    }

    public static var breathe: Animation {
        .easeInOut(duration: breathPeriod).repeatForever(autoreverses: true)
    }

    /// Looping breathe animation, or `nil` under Reduce Motion so call sites collapse to the resting frame.
    public static func breathe(reduced: Bool) -> Animation? {
        reduced ? nil : breathe
    }

    public static let pulse = Animation.easeOut(duration: 0.6)

    public static let fade = Animation.easeInOut(duration: durationStandard)

    // MARK: Compact charge-to-sync indicator
    //
    // Only `syncIndicatorSignalDebounceNanoseconds` is `public`: the screen owns the raw sync signal and
    // must debounce it. The rest is the indicator's internal timing, used only by `ChargeSyncIndicator`.

    static let syncIndicatorMorph = Animation.spring(
        response: 0.60,
        dampingFraction: 0.94,
        blendDuration: 0.14
    )

    /// Coordinated charge-number, arc and colour transition. Matched to the wind-down's average half-turn
    /// (`2 · 180 / rate`) so both halves are the same length. Linear on purpose: `entryBody` applies smootherstep itself.
    static var syncIndicatorVisual: Animation {
        .linear(duration: syncIndicatorMorphDuration)
    }

    /// Length of BOTH halves of the morph: constant deceleration over `syncIndicatorExitTravelDegrees` takes `2 · distance / rate`.
    static var syncIndicatorMorphDuration: Double {
        2 * syncIndicatorExitTravelDegrees / syncIndicatorSpinRateDegrees
    }

    /// Half-width, in turns, of the blend band that travels along the arc as it changes colour.
    static let syncIndicatorTintBandTurns: Double = 0.10

    static let syncIndicatorLabelIn = Animation.easeOut(duration: 0.26)
    static let syncIndicatorLabelOut = Animation.easeInOut(duration: 0.26)

    static let syncIndicatorFrameInterval = 1.0 / 60.0
    static let syncIndicatorSpinPeriod = 1.25

    /// Fixed sweep of the spinner arc, in turns. Deliberately NOT breathing: rotation is anchored to the
    /// head, so a breathing length modulates the tail speed by ~±17% and the wobble recurs at the same
    /// screen position each revolution. Constant length also lets the wind-down hand off cleanly.
    static let syncIndicatorSpinnerArcTurns = 0.38

    /// Distance the wind-down covers, fixed so the exit always matches the entry's length.
    static let syncIndicatorExitTravelDegrees: Double = 180

    /// Grace period the SCREEN applies to the falling edge of the sync signal before winding down. Public
    /// because `backfilling` drops between history chunks and the control would otherwise flap mid-sync.
    public static let syncIndicatorSignalDebounceNanoseconds: UInt64 = 3_000_000_000

    static let syncIndicatorLabelDelayNanoseconds: UInt64 = 650_000_000
    static let syncIndicatorLabelVisibilityNanoseconds: UInt64 = 1_900_000_000
    static let syncIndicatorCollapseDelayNanoseconds: UInt64 = 240_000_000
    /// Steady spinner rate in degrees per second, derived from the spin period so the wind-down stays in step.
    static var syncIndicatorSpinRateDegrees: Double { 360 / syncIndicatorSpinPeriod }

    /// Grace after the wind-down lands before the morph view is torn down, so the swap happens on a settled frame.
    static let syncIndicatorExitSettleMargin: Double = 0.06

    /// How far the ring must sweep for the battery colour to finish becoming the sync colour. A full turn,
    /// so the colour lands as the entry ends (the ring carries 360° by then, not 180°).
    static let syncIndicatorColourTravelDegrees: Double = 360

    // MARK: Charge-to-sync curve math
    //
    // Pure and unit-testable. Lives here because BOTH `ChargeSyncIndicator` and `ChargeSyncMorph` read the
    // same spin clock; two copies of the curve would put the wind-down where the ring is not.

    /// Where the spinner is at `date`: rotation in degrees since `start` and the arc's fixed length in
    /// turns. `posed` (motion-saving) parks it at 0° so the static state is the moving one stopped.
    static func syncIndicatorPhase(
        since start: Date?,
        at date: Date,
        posed: Bool
    ) -> (degrees: Double, arc: Double) {
        let arc = syncIndicatorSpinnerArcTurns
        guard !posed else { return (0, arc) }
        let seconds = max(0, date.timeIntervalSince(start ?? date))
        return ((seconds / syncIndicatorSpinPeriod) * 360, arc)
    }

    /// Smootherstep (6t⁵ − 15t⁴ + 10t³). Every value the ENTRY interpolates rides this one curve so they
    /// land together. Zeroes the second derivative too, unlike smoothstep, so there is no acceleration kick.
    static func syncIndicatorSmootherStep(_ value: Double) -> Double {
        let t = max(0, min(1, value))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// Quadratic ease-out, `1 − (1 − t)²`: constant deceleration, slope 2 at t = 0. Used for the wind-down so the ring coasts to a stop.
    static func syncIndicatorEaseOutQuad(_ value: Double) -> Double {
        let t = max(0, min(1, value))
        return 1 - (1 - t) * (1 - t)
    }

    /// Position, in turns, of the travelling colour boundary along an arc of length `arc` at `tint`. Sweeps
    /// from `arc + band` to `−band` so the blend band clears the arc completely at BOTH ends.
    static func syncIndicatorTintBoundary(tint: Double, arc: Double) -> Double {
        let band = syncIndicatorTintBandTurns
        return arc + band - tint * (arc + 2 * band)
    }
}

#if DEBUG
private struct MotionDemo: View {
    @State private var on = false
    @State private var breathing = false
    var body: some View {
        VStack(spacing: 32) {
            Circle()
                .fill(StrandPalette.accent)
                .frame(width: 60, height: 60)
                .offset(y: on ? -24 : 24)
                .animation(StrandMotion.gentle, value: on)
            Circle()
                .fill(StrandPalette.recovery100)
                .frame(width: 60, height: 60)
                .scaleEffect(breathing ? 1.12 : 0.9)
                .opacity(breathing ? 0.9 : 0.5)
                .onAppear { breathing = true }
                .animation(StrandMotion.breathe, value: breathing)
            Button("Toggle gentle spring") { on.toggle() }
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .frame(width: 360, height: 320)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
    }
}

#Preview("Motion") { MotionDemo() }
#endif
