import SwiftUI

/// Ring geometry and glyph tones for the charge-to-sync control. Named so the entry and wind-down
/// interpolate between the SAME battery and spinner values. File-private (not `ZoopMetrics`) because
/// these are drawing values, not layout spacing.
private enum SyncRing {
    /// Stroke weight of the resting battery arc, and of the spinner it becomes.
    static let batteryWidth: CGFloat = 3.0
    static let spinnerWidth: CGFloat = 2.6
    /// The unfilled track behind the spinner arc.
    static let trackWidth: CGFloat = 2.4
    static let trackOpacity: Double = 0.13

    /// Point size of the central numeral; shared by battery percentage and chunk tally so one replaces the other in place.
    static let numberSize: CGFloat = 9
    /// Numeral tone.
    static let numberOpacity: Double = 0.9
    static let numberMinScale: Double = 0.92

    /// The charging bolt: point size, and how far above centre it clears the ring.
    static let boltSize: CGFloat = 7
    static let boltOffset: CGFloat = -10

    /// Glyph size for symbol states (bolt is a real reading, the ellipsis stands in for a missing one).
    static let symbolGlyphSize: CGFloat = 11
    static let ellipsisGlyphSize: CGFloat = 9
    static let dimGlyphOpacity: Double = 0.5

    /// The transient "Syncing" label's tone.
    static let labelOpacity: Double = 0.92

    /// Stroke weight `eased` of the way from battery ring to spinner; the wind-down passes the inverse so both share one ramp.
    static func width(eased: Double) -> CGFloat {
        batteryWidth + (spinnerWidth - batteryWidth) * eased
    }

    /// Numeral scale for a crossfade at `opacity`, easing down to `numberMinScale`.
    static func numberScale(opacity: Double) -> Double {
        numberMinScale + (1 - numberMinScale) * opacity
    }
}

/// Compact strap-battery chrome that morphs into an activity indicator while history syncs. Its expanded
/// width participates in layout, pushing earlier controls aside. Motion-saving modes use a static state.
public struct ChargeSyncIndicator: View {
    public enum BatteryState: Equatable {
        case offline
        case pending(charging: Bool)
        case charge(percent: Double, charging: Bool)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = ZoopMotionState.shared

    private var poseStill: Bool { motion.poseStill(reduceMotion) }

    private let batteryState: BatteryState
    private let syncing: Bool
    /// Chunks acked this session, shown inside the spinner where the battery percentage sits when idle. 0 shows nothing.
    private let chunks: Int
    private let label: LocalizedStringKey

    /// The label's natural width, measured by `labelWidthReader`; 0 until the first layout pass.
    @State private var labelWidth: CGFloat = 0
    @State private var visualProgress = 0.0
    @State private var pillProgress = 0.0
    @State private var endingSync = false
    @State private var animationActive = false
    @State private var showsLabel = false
    @State private var spinStartedAt: Date?
    /// Spin angle the CURRENT entry started from. The entry sweeps `(spin − this) · eased`: `spinStartedAt`
    /// is not reset when a sync begins during a wind-down, so the raw angle can be thousands of degrees.
    @State private var spinBaseDegrees = 0.0
    @State private var exitStartDegrees = 0.0
    @State private var exitStartArc = 0.30
    /// The arc the battery ring draws, in turns; mirrors `ChargeSyncMorph` so the exit picks up at the entry's angle.
    private var currentBatteryArc: Double {
        guard case .charge(let percent, _) = batteryState else { return 0 }
        return max(0.02, min(1, percent / 100))
    }
    @State private var announcementTask: Task<Void, Never>?
    @State private var settleTask: Task<Void, Never>?
    /// A sync that arrived mid wind-down, held until the ring is at rest (see `beginSync`).
    @State private var restartAfterSettle = false

    public init(
        batteryState: BatteryState,
        syncing: Bool,
        chunks: Int = 0,
        label: LocalizedStringKey = "Syncing"
    ) {
        self.batteryState = batteryState
        self.syncing = syncing
        self.chunks = chunks
        self.label = label
    }

    /// Capsule width once expanded: ring, gap, label at natural width, same trailing gap. Capped at
    /// `syncIndicatorExpandedWidth`, so the longest translations shrink to fit rather than widening the header.
    private var expandedWidth: CGFloat {
        Self.expandedWidth(labelWidth: labelWidth)
    }

    /// Reports the label's natural width from a `background`, so it never affects layout.
    private var labelWidthReader: some View {
        Text(label, bundle: .module)
            .font(StrandFont.overline)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .dynamicTypeSize(...DynamicTypeSize.large)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SyncLabelWidthKey.self,
                        value: proxy.size.width
                    )
                }
            )
            .opacity(0)
            .accessibilityHidden(true)
    }

    public var body: some View {
        ZStack(alignment: .leading) {
            indicatorContents
                .frame(
                    width: ZoopMetrics.compactControlSize,
                    height: ZoopMetrics.compactControlSize
                )

            // `bundle: .module`: `Text(LocalizedStringKey)` resolves against the APP bundle otherwise. `overline`
            // supplies face and weight but not its tracking, since this is sentence-case status copy.
            Text(label, bundle: .module)
                .font(StrandFont.overline)
                .foregroundStyle(StrandPalette.textPrimary.opacity(SyncRing.labelOpacity))
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(ZoopMetrics.syncIndicatorMinimumLabelScale)
                .dynamicTypeSize(...DynamicTypeSize.large)
                .frame(
                    width: expandedWidth
                        - ZoopMetrics.compactControlSize
                        - ZoopMetrics.syncIndicatorLabelSpacing,
                    alignment: .leading
                )
                .offset(
                    x: ZoopMetrics.compactControlSize
                        + ZoopMetrics.syncIndicatorLabelSpacing
                )
                .opacity(showsLabel ? 1 : 0)
                .accessibilityHidden(true)
        }
        // Measure ABOVE the animated frame: below it, the reader sees the mid-animation width, rewrites
        // `labelWidth`, and re-targets the spring every frame (the circle-to-pill glitch).
        .background(labelWidthReader, alignment: .leading)
        .onPreferenceChange(SyncLabelWidthKey.self) { measured in
            // Ignore sub-point churn so a rounding wobble cannot restart the animation.
            guard measured > 0, abs(measured - labelWidth) > 0.5 else { return }
            labelWidth = measured
        }
        .frame(
            width: ZoopMetrics.compactControlSize
                + (expandedWidth - ZoopMetrics.compactControlSize)
                * CGFloat(pillProgress),
            height: ZoopMetrics.compactControlSize,
            alignment: .leading
        )
        // No surface of its own: the host supplies the chrome (`nativeLiquidGlassSyncButton()`), so glyphs can follow theme tones.
        .clipShape(Capsule(style: .continuous))
        .contentShape(Capsule(style: .continuous))
        .onAppear { updateSyncState(syncing) }
        .onChangeCompat(of: syncing) { updateSyncState($0) }
        .onDisappear {
            announcementTask?.cancel()
            settleTask?.cancel()
            // Land at rest rather than freezing mid-morph, so a later re-appearance does not queue behind a wind-down that never finishes.
            finishSyncImmediately()
            restartAfterSettle = false
        }
    }

    @ViewBuilder
    private var indicatorContents: some View {
        switch batteryState {
        case .charge(let percent, let charging):
            ChargeSyncMorph(
                progress: visualProgress,
                ending: endingSync,
                active: animationActive,
                reducedMotion: poseStill,
                percent: percent,
                charging: charging,
                batteryTint: Self.ringColor(percent),
                spinBaseDegrees: spinBaseDegrees,
                chunks: chunks,
                spinStartedAt: spinStartedAt,
                exitStartDegrees: exitStartDegrees,
                exitStartArc: exitStartArc
            )
        default:
            ZStack {
                batteryContents.opacity(1 - visualProgress)
                syncingContents.opacity(visualProgress)
            }
        }
    }

    @ViewBuilder
    private var batteryContents: some View {
        switch batteryState {
        case .charge(let percent, let charging):
            Circle()
                .trim(from: 0, to: max(0.02, min(1, percent / 100)))
                .stroke(
                    Self.ringColor(percent),
                    style: StrokeStyle(lineWidth: SyncRing.batteryWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(ZoopMetrics.syncIndicatorArcInset)
            Text("\(Int(percent.rounded()))")
                .font(StrandFont.number(SyncRing.numberSize, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary.opacity(SyncRing.numberOpacity))
            if charging {
                Image(systemName: "bolt.fill")
                    .font(StrandFont.number(SyncRing.boltSize, weight: .bold))
                    .foregroundStyle(StrandPalette.chargeColor)
                    .offset(y: SyncRing.boltOffset)
            }
        case .pending(let charging):
            Image(systemName: charging ? "bolt.fill" : "ellipsis")
                .font(
                    StrandFont.number(
                        charging ? SyncRing.symbolGlyphSize : SyncRing.ellipsisGlyphSize,
                        weight: .bold
                    )
                )
                .foregroundStyle(
                    charging
                        ? StrandPalette.chargeColor
                        : StrandPalette.textPrimary.opacity(SyncRing.dimGlyphOpacity)
                )
        case .offline:
            Image(systemName: "bolt.slash")
                .font(StrandFont.number(SyncRing.symbolGlyphSize))
                .foregroundStyle(StrandPalette.textPrimary.opacity(SyncRing.dimGlyphOpacity))
        }
    }

    /// The spinner. Still while idle or quiet, with no timeline behind it; always in the tree, at opacity 0 when no sync runs.
    @ViewBuilder
    private var syncingContents: some View {
        if animationActive && !poseStill {
            TimelineView(.animation(minimumInterval: StrandMotion.syncIndicatorFrameInterval)) { timeline in
                spinner(at: timeline.date)
            }
        } else {
            spinner(at: Date())
        }
    }

    private func spinner(at date: Date) -> some View {
        let phase = syncPhase(at: date)
        return ZStack {
            Circle()
                .stroke(
                    StrandPalette.liquidHeart.opacity(SyncRing.trackOpacity),
                    lineWidth: SyncRing.trackWidth
                )
                .padding(ZoopMetrics.syncIndicatorArcInset)
            Circle()
                .trim(from: 0, to: phase.arc)
                .stroke(
                    StrandPalette.liquidHeart,
                    style: StrokeStyle(lineWidth: SyncRing.spinnerWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(phase.degrees - 90))
                .padding(ZoopMetrics.syncIndicatorArcInset)
            chunkNumber
        }
    }

    /// The chunk tally inside the spinner, sharing the battery percentage's font and centre. Hidden at 0.
    @ViewBuilder
    private var chunkNumber: some View {
        if chunks > 0 {
            Text("\(chunks)")
                .font(StrandFont.number(SyncRing.numberSize, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary.opacity(SyncRing.numberOpacity))
                .accessibilityHidden(true)
        }
    }

    private func updateSyncState(_ active: Bool) {
        if active {
            beginSync()
        } else {
            endSync()
        }
    }

    /// Snaps to the settled battery state with no motion. Shared by the Reduce-Motion path, the settle task
    /// (which must re-check), and `onDisappear`.
    private func finishSyncImmediately() {
        visualProgress = 0
        pillProgress = 0
        showsLabel = false
        animationActive = false
        spinStartedAt = nil
        spinBaseDegrees = 0
        endingSync = false
    }

    /// True only for the state whose ring the wind-down parks at 12 o'clock; `.offline` and `.pending` crossfade.
    private var alignsRingOnExit: Bool {
        if case .charge = batteryState { return true }
        return false
    }

    /// Resumes a sync that arrived mid wind-down. Drops the settle handle FIRST: this runs inside that task,
    /// and `beginSync` cancels `settleTask`.
    private func restartIfPending() {
        settleTask = nil
        guard restartAfterSettle else { return }
        restartAfterSettle = false
        beginSync()
    }

    private func beginSync() {
        // Mid wind-down: do NOT cut in. `entryBody` and `exitBody` draw different geometry for the same
        // `visualProgress`, so swapping mid-flight snaps the ring. Let it land, then start a fresh entry from the static battery ring.
        if endingSync {
            restartAfterSettle = true
            return
        }

        settleTask?.cancel()
        announcementTask?.cancel()
        restartAfterSettle = false
        endingSync = false

        if animationActive {
            // Already spinning, exit scheduled but not drawing: cancelling that task is the whole resume.
            // Re-anchoring `spinBaseDegrees` here would zero `travel` and snap the head back.
        } else {
            spinStartedAt = Date()
            animationActive = true
            spinBaseDegrees = 0
        }
        showsLabel = false
        animate(poseStill ? nil : StrandMotion.syncIndicatorVisual) {
            visualProgress = 1
        }
        animate(poseStill ? nil : StrandMotion.syncIndicatorMorph) {
            pillProgress = 1
        }

        if poseStill {
            showsLabel = true
        }

        announcementTask = Task { @MainActor in
            if !poseStill {
                try? await Task.sleep(
                    nanoseconds: StrandMotion.syncIndicatorLabelDelayNanoseconds
                )
                guard !Task.isCancelled else { return }
            }
            animate(poseStill ? nil : StrandMotion.syncIndicatorLabelIn) {
                showsLabel = true
            }

            try? await Task.sleep(
                nanoseconds: StrandMotion.syncIndicatorLabelVisibilityNanoseconds
            )
            guard !Task.isCancelled else { return }
            animate(poseStill ? nil : StrandMotion.syncIndicatorLabelOut) {
                showsLabel = false
            }
            try? await Task.sleep(
                nanoseconds: StrandMotion.syncIndicatorCollapseDelayNanoseconds
            )
            guard !Task.isCancelled else { return }
            animate(poseStill ? nil : StrandMotion.syncIndicatorMorph) {
                pillProgress = 0
            }
        }
    }

    private func endSync() {
        announcementTask?.cancel()
        restartAfterSettle = false

        guard animationActive else {
            settleTask?.cancel()
            visualProgress = 0
            pillProgress = 0
            showsLabel = false
            return
        }

        if poseStill {
            settleTask?.cancel()
            finishSyncImmediately()
            return
        }

        // A wind-down already drawing finishes on its own terms.
        guard !endingSync else { return }
        settleTask?.cancel()

        // The wind-down always covers the SAME distance so it matches the entry's length. Rather than braking
        // from wherever it is, wait for the ring to reach the point that far out; at most one extra revolution.
        let rate = StrandMotion.syncIndicatorSpinRateDegrees
        let target = StrandMotion.syncIndicatorExitTravelDegrees
        let duration = StrandMotion.syncIndicatorMorphDuration

        let phase = syncPhase(at: Date())
        // The tail `entryBody` ACTUALLY draws (head minus length, base included), not the raw spin angle.
        let renderedTail = currentBatteryArc * 360
            + (phase.degrees - spinBaseDegrees)
            - phase.arc * 360
        let wrapped = renderedTail.truncatingRemainder(dividingBy: 360)
        let tailAngle = wrapped < 0 ? wrapped + 360 : wrapped
        let alignment = ((target - tailAngle).truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / rate
        // ONLY `.charge` has a ring to park; `.offline` and `.pending` have no hand-off angle to wait for.
        let lead = alignsRingOnExit ? alignment : 0

        animate(StrandMotion.syncIndicatorMorph) {
            showsLabel = false
            pillProgress = 0
        }

        settleTask = Task { @MainActor in
            if lead > 0 {
                try? await Task.sleep(nanoseconds: UInt64(lead * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }

            // RE-CHECK: Reduce Motion (or Low Power) can be switched on during the wait above.
            guard !poseStill else {
                finishSyncImmediately()
                restartIfPending()
                return
            }

            let atStart = syncPhase(at: Date())
            exitStartDegrees = currentBatteryArc * 360
                + (atStart.degrees - spinBaseDegrees)
                - atStart.arc * 360
            exitStartArc = atStart.arc
            endingSync = true
            // Linear in time: `exitBody` applies the deceleration curve analytically.
            animate(.linear(duration: duration)) {
                visualProgress = 0
            }

            try? await Task.sleep(
                nanoseconds: UInt64(
                    (duration + StrandMotion.syncIndicatorExitSettleMargin) * 1_000_000_000
                )
            )
            guard !Task.isCancelled else { return }
            animationActive = false
            spinStartedAt = nil
            spinBaseDegrees = 0
            endingSync = false
            restartIfPending()
        }
    }

    private func syncPhase(at date: Date) -> (degrees: Double, arc: Double) {
        StrandMotion.syncIndicatorPhase(since: spinStartedAt, at: date, posed: poseStill)
    }

    private func animate(_ animation: Animation?, changes: () -> Void) {
        withAnimation(animation, changes)
    }

    /// The three bands a strap charge reads in. Split from the colour lookup so a test can pin the thresholds
    /// (SwiftUI `Color` is not `==` across reads).
    enum ChargeBand: Equatable {
        case critical
        case warning
        case healthy
    }

    /// Boundaries belong to the calmer band above them, so exactly 35 is not a warning.
    static func chargeBand(_ percent: Double) -> ChargeBand {
        if percent < 15 { return .critical }
        if percent < 35 { return .warning }
        return .healthy
    }

    static func ringColor(_ percent: Double) -> Color {
        switch chargeBand(percent) {
        case .critical: return StrandPalette.statusCritical
        case .warning:  return StrandPalette.statusWarning
        case .healthy:  return StrandPalette.chargeColor
        }
    }

    /// The capsule's expanded width for a label of `labelWidth`; never below the compact circle, capped at the max.
    static func expandedWidth(labelWidth: CGFloat) -> CGFloat {
        let hugged = ZoopMetrics.compactControlSize
            + ZoopMetrics.syncIndicatorLabelSpacing
            + labelWidth
            + ZoopMetrics.syncIndicatorLabelSpacing
        return min(
            ZoopMetrics.syncIndicatorExpandedWidth,
            max(ZoopMetrics.compactControlSize, hugged)
        )
    }
}

/// Carries the sync label's natural width out of the measuring background.
private struct SyncLabelWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ChargeSyncMorph: View, Animatable {
    var progress: Double
    let ending: Bool
    let active: Bool
    let reducedMotion: Bool
    let percent: Double
    let charging: Bool
    /// Slack past the arc's head where its colour is held constant so the round lineCap samples a pure colour. See `arcSweep`.
    static let capPadTurns = 0.03

    let batteryTint: Color
    /// Spin base for the morph's own reads, mirroring the entry.
    let spinBaseDegrees: Double
    let chunks: Int
    let spinStartedAt: Date?
    let exitStartDegrees: Double
    let exitStartArc: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        // At rest, or with motion unwanted, draw one still frame with no timeline: a paused timeline still
        // cost 15 to 51 CPU-seconds a minute in the render server when this ring sits in Today's header.
        if !active || reducedMotion {
            frame(at: Date())
        } else {
            TimelineView(.animation(minimumInterval: StrandMotion.syncIndicatorFrameInterval)) { timeline in
                frame(at: timeline.date)
            }
        }
    }

    @ViewBuilder
    private func frame(at date: Date) -> some View {
        let p = max(0, min(1, progress))
        let phase = syncPhase(at: date)
        let batteryArc = max(0.02, min(1, percent / 100))

        if ending {
            exitBody(progress: p, batteryArc: batteryArc)
        } else {
            entryBody(
                progress: p,
                batteryArc: batteryArc,
                spinnerArc: phase.arc,
                // Relative to where this entry began.
                spinDegrees: phase.degrees - spinBaseDegrees
            )
        }
    }

    private func exitBody(progress: Double, batteryArc: Double) -> some View {
        let exit = 1 - progress
        // Quadratic ease-out, NOT smootherstep: slope 2 at the start matches the steady spin rate, so the
        // spinner coasts to a stop. (Entry keeps smootherstep: it departs from a static ring.)
        let eased = StrandMotion.syncIndicatorEaseOutQuad(exit)

        let wrapped = exitStartDegrees.truncatingRemainder(dividingBy: 360)
        let remainder = wrapped < 0 ? wrapped + 360 : wrapped
        let degreesToTop = remainder == 0 ? 0 : 360 - remainder
        let degrees = exitStartDegrees + degreesToTop * eased
        // Length converges on the same curve as rotation, so the arc becomes the percentage as the ring stops at 12 o'clock.
        let arc = exitStartArc + (batteryArc - exitStartArc) * eased
        // One radius across the whole morph.
        let inset = ZoopMetrics.syncIndicatorArcInset
        // `1 − eased`: the wind-down runs the entry's ramp backwards.
        let lineWidth = SyncRing.width(eased: 1 - eased)

        return ZStack {
            Circle()
                .stroke(
                    StrandPalette.liquidHeart.opacity(SyncRing.trackOpacity * (1 - eased)),
                    lineWidth: SyncRing.trackWidth
                )
                .padding(inset)
            // One stroke with a travelling colour boundary (see `arcSweep`); on exit the battery colour grows back from the tail.
            Circle()
                .trim(from: 0, to: arc)
                .stroke(
                    arcSweep(tint: 1 - eased, arc: arc),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(degrees - 90))
                .padding(inset)
            batteryNumber(opacity: eased)
            chunkNumber(opacity: 1 - eased)
        }
    }

    private func entryBody(
        progress: Double,
        batteryArc: Double,
        spinnerArc: Double,
        spinDegrees: Double
    ) -> some View {
        let eased = StrandMotion.syncIndicatorSmootherStep(progress)
        let arc = batteryArc + (spinnerArc - batteryArc) * eased

        // Rotation is anchored to the arc's HEAD so the spin starts where the percentage sits. `trim` draws
        // tail-first, so tail = head minus the (shrinking) length.
        let travel = reducedMotion ? 0 : spinDegrees * eased
        let head = batteryArc * 360 + travel
        let degrees = head - arc * 360

        // Tint trails the motion (driven by sweep travel, not `eased`) so it reads as a transformation, not a swap.
        // Reduced motion has no travel, so it uses the shape's own curve.
        let tint = reducedMotion
            ? eased
            : min(1, travel / StrandMotion.syncIndicatorColourTravelDegrees)

        let inset = ZoopMetrics.syncIndicatorArcInset
        let lineWidth = SyncRing.width(eased: eased)

        return ZStack {
            Circle()
                .stroke(
                    StrandPalette.liquidHeart.opacity(SyncRing.trackOpacity * tint),
                    lineWidth: SyncRing.trackWidth
                )
                .padding(inset)
            Circle()
                .trim(from: 0, to: arc)
                .stroke(
                    arcSweep(tint: tint, arc: arc),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(degrees - 90))
                .padding(inset)
            batteryNumber(opacity: 1 - tint)
            chunkNumber(opacity: tint)
        }
    }

    /// The arc's stroke as a sweep that turns over ALONG its length: the head carries the sync colour first
    /// and the boundary travels toward the tail as `tint` rises, with a soft band. Locations are in turns,
    /// aligned with `trim`; `rotationEffect` carries the gradient, so location 0 is always the tail.
    private func arcSweep(tint: Double, arc: Double) -> AngularGradient {
        let band = StrandMotion.syncIndicatorTintBandTurns
        let boundary = StrandMotion.syncIndicatorTintBoundary(tint: tint, arc: arc)

        let tailColor = boundary > 0 ? batteryTint : StrandPalette.liquidHeart
        let headColor = boundary < arc ? StrandPalette.liquidHeart : batteryTint

        // An AngularGradient WRAPS: the round cap at the tail overhangs before 0° and samples near location 1,
        // so the final stop must be the TAIL's colour. `headPad` does the same at the head (cap overhang is ~6°).
        let headPad = min(1, arc + ChargeSyncMorph.capPadTurns)
        let low = max(0, min(headPad, boundary - band))
        let high = max(low, min(headPad, boundary + band))
        return AngularGradient(
            stops: [
                .init(color: tailColor, location: 0),
                .init(color: tailColor, location: low),
                .init(color: headColor, location: high),
                .init(color: headColor, location: headPad),
                .init(color: tailColor, location: 1),
            ],
            center: .center,
            startAngle: .degrees(0),
            endAngle: .degrees(360)
        )
    }

    /// The chunk tally, crossfading in as the battery percentage fades out. Hidden at 0.
    @ViewBuilder
    private func chunkNumber(opacity: Double) -> some View {
        if chunks > 0 {
            Text("\(chunks)")
                .font(StrandFont.number(SyncRing.numberSize, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary.opacity(SyncRing.numberOpacity))
                .scaleEffect(SyncRing.numberScale(opacity: opacity))
                .opacity(opacity)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func batteryNumber(opacity: Double) -> some View {
        Text("\(Int(percent.rounded()))")
            .font(StrandFont.number(SyncRing.numberSize, weight: .bold))
            .foregroundStyle(StrandPalette.textPrimary.opacity(SyncRing.numberOpacity))
            .scaleEffect(SyncRing.numberScale(opacity: opacity))
            .opacity(opacity)
        if charging {
            Image(systemName: "bolt.fill")
                .font(StrandFont.number(SyncRing.boltSize, weight: .bold))
                .foregroundStyle(StrandPalette.chargeColor)
                .offset(y: SyncRing.boltOffset)
                .opacity(opacity)
        }
    }

    /// The same clock `ChargeSyncIndicator` reads when it captures the hand-off angle; one shared implementation so they cannot diverge.
    private func syncPhase(at date: Date) -> (degrees: Double, arc: Double) {
        StrandMotion.syncIndicatorPhase(since: spinStartedAt, at: date, posed: reducedMotion)
    }
}

public extension View {
    /// Fades long header copy underneath a trailing control row while reserving its footprint. `reserving`
    /// is the width the HOST measures; `headerControlReserveWidth` is only the pre-measurement default.
    func headerTrailingControlFadeMask(
        reserving reserve: CGFloat = ZoopMetrics.headerControlReserveWidth
    ) -> some View {
        mask {
            HStack(spacing: 0) {
                Color.black
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: ZoopMetrics.headerTextFadeWidth)
                Color.clear.frame(width: max(0, reserve))
            }
        }
    }
}

#if DEBUG
private struct ChargeSyncIndicatorPreview: View {
    @State private var syncing = false
    private let greeting = "Good evening, Maximilian Alexander"
    private var toggleTitle: String {
        syncing ? "Finish sync" : "Start sync"
    }

    var body: some View {
        VStack(spacing: ZoopMetrics.space5) {
            HStack(spacing: ZoopMetrics.space2) {
                Text(verbatim: greeting)
                    .font(StrandFont.title1)
                    .foregroundStyle(StrandPalette.onDarkPrimary)
                    .lineLimit(2)
                    .headerTrailingControlFadeMask()
                HStack(spacing: ZoopMetrics.space1) {
                    Circle()
                        .fill(StrandPalette.onDarkPrimary.opacity(0.16))
                        .frame(
                            width: ZoopMetrics.compactControlSize,
                            height: ZoopMetrics.compactControlSize
                        )
                    ChargeSyncIndicator(
                        batteryState: .charge(percent: 68, charging: false),
                        syncing: syncing
                    )
                    Circle()
                        .fill(StrandPalette.onDarkPrimary.opacity(0.16))
                        .frame(
                            width: ZoopMetrics.compactControlSize,
                            height: ZoopMetrics.compactControlSize
                        )
                }
            }

            Button {
                syncing.toggle()
            } label: {
                Text(verbatim: toggleTitle)
            }
            .font(StrandFont.body)
        }
        .padding(ZoopMetrics.space5)
        .frame(width: 440, height: 180)
        .background(StrandPalette.accent)
        .preferredColorScheme(.dark)
    }
}

/// The control as a host presents it: chrome supplied from outside on a theme-following surface, so the backdrop flips with the scheme.
private struct ChargeSyncIndicatorHosted: View {
    var syncing = true

    var body: some View {
        ChargeSyncIndicator(
            batteryState: .charge(percent: 68, charging: false),
            syncing: syncing,
            chunks: 3
        )
        .padding(ZoopMetrics.syncIndicatorGlassPadding)
        .background(Capsule(style: .continuous).fill(StrandPalette.heroFill))
        .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.heroBorder, lineWidth: 1))
        .padding(ZoopMetrics.space5)
    }
}

#Preview("Charge to sync morph") {
    ChargeSyncIndicatorPreview()
}

// Both schemes: Light is the case that regressed when the control carried a fixed near-black surface.
#Preview("Charge sync active — Dark") {
    ChargeSyncIndicatorHosted()
        .preferredColorScheme(.dark)
}

#Preview("Charge sync active — Light") {
    ChargeSyncIndicatorHosted()
        .preferredColorScheme(.light)
}

#Preview("Charge idle — Light") {
    ChargeSyncIndicatorHosted(syncing: false)
        .preferredColorScheme(.light)
}
#endif
