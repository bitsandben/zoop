import SwiftUI
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
// Explicit AppKit import: this file names NSApplication/NSWindow directly for the window-visibility gate (#2393).
import AppKit
#endif

// MARK: - ZoopMotion — the house motion set
// Smooth, snappy, almost no bounce; no glow and nothing that pulses or loops. Provides a spring/transition set, `CountUpText`,
// `.staggeredAppear(index:)` and `.softCardTransition()`. Count-up and stagger honour the shared quiet-motion gate.
// Complements `StrandMotion` (organic breathe/pulse); this set is crisp and mechanical.

public enum ZoopMotion {

    // MARK: Springs — smooth, snappy, minimal bounce

    /// Screen-level spring: page pushes, sheet/tab swaps, large layout moves.
    public static let screen = Animation.spring(response: 0.46, dampingFraction: 0.88)

    /// Card-level spring, the house tempo: card insert/remove, row reflow, expand/collapse.
    public static let card = Animation.spring(response: 0.40, dampingFraction: 0.85)

    /// Value-level spring: number ticks, gauge fraction, chip changes; tightly damped, no overshoot.
    public static let value = Animation.spring(response: 0.34, dampingFraction: 0.90)

    // MARK: Stagger

    /// Per-item delay for a staggered reveal: item n waits `n * stagger`.
    public static let stagger: Double = 0.04

    /// The pre-reveal vertical offset for a staggered/appear item (rises UP into place).
    public static let riseOffset: CGFloat = 8

    // MARK: Reduce-Motion gating

    /// Returns `animation`, or `nil` (snap to the final frame) when Reduce Motion is on. Mirrors `StrandMotion.drawIn(reduced:)`.
    @inline(__always)
    public static func gated(_ animation: Animation, reduced: Bool) -> Animation? {
        reduced ? nil : animation
    }
}

// MARK: - Quiet Motion — the ONE gate every never-settling animation consults
// Covers the liquid layer, atmosphere drift, guardian breath and connection halo. Three signals, OR-ed:
// 1. `accessibilityReduceMotion`, supplied by the call site (only a View can read the environment).
// 2. Low Power Mode.
// 3. "Reduce motion in Zoop", an in-app preference, default OFF.

/// "Reduce motion in Zoop" (opt-in, default OFF): poses every looping animation still and stops the decorative motion sensor. Toggled from Settings → Appearance.
/// Apple-only for now (#941). The key string is the cross-platform contract: Android must adopt "zoop.quietMotion" verbatim so a `.zoopbak` round-trip carries it.
public enum QuietMotionPrefs {
    /// The `@AppStorage` / `UserDefaults` key shared by the Settings toggle and `ZoopMotionState`.
    public static let enabledKey = "zoop.quietMotion"
}

/// Publishes the motion signals with no SwiftUI environment key (Low Power Mode, the in-app preference) so any view can pose its looping animation still.
/// One `NotificationCenter` observer rather than per-view registration: the liquid primitives have dozens of call sites. A continuously animating `Canvas`
/// is not free: ~18% of a core idle on Today in a simulator, 0% once the live surfaces pose still.
@MainActor
public final class ZoopMotionState: ObservableObject {
    public static let shared = ZoopMotionState()

    /// System Low Power Mode / battery saver. Live via `.NSProcessInfoPowerStateDidChange`, so toggling needs no relaunch.
    @Published public private(set) var isLowPower: Bool

    /// macOS only (#2393): every app window is hidden, minimised or fully covered, so nothing a frame loop draws can be seen.
    /// A decorative `TimelineView(.animation…)` keeps running when hidden (Cmd+H even raised it, 28.8% to 49.3% of a core); drawing unseen frames is not worth it.
    /// iOS and watchOS never set this: the system stops rendering a backgrounded app and `scenePhase` covers the rest.
    @Published public private(set) var windowObscured: Bool = false

    /// The in-app "Reduce motion in Zoop" preference, kept in step with `UserDefaults` so the motion sensor and the `@AppStorage` toggle never disagree.
    @Published public private(set) var quietMotion: Bool

    private init() {
        isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        quietMotion = UserDefaults.standard.bool(forKey: QuietMotionPrefs.enabledKey)
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
        // `@AppStorage` writes UserDefaults without notifying us, so mirror it via `.didChangeNotification` (covers a write from any target).
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let now = UserDefaults.standard.bool(forKey: QuietMotionPrefs.enabledKey)
                if self?.quietMotion != now { self?.quietMotion = now }
            }
        }
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        // Hide/unhide, occlusion and miniaturise notifications all land on one recompute: the states overlap (hiding occludes windows),
        // so a flag written from several places would disagree with itself on out-of-order arrival.
        for name in [NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification,
                     NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshWindowObscured() }
            }
        }
        #endif
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    /// Recompute [windowObscured] from AppKit's window list; cheap, and runs only on user-driven notifications.
    private func refreshWindowObscured() {
        // Filter on `.titled`: it separates real app windows from the `MenuBarExtra` status-item window, which lives for the whole process and would report something on screen forever.
        // Not `canBecomeMain`: it describes current state, so a hidden or miniaturised window answered false, the list emptied, and the empty-list rule below read that as not obscured (#2397).
        let windows = NSApplication.shared.windows
            .filter { $0.styleMask.contains(.titled) }
            .map { WindowVisibility(onScreen: $0.isVisible && $0.occlusionState.contains(.visible)) }
        let now = ZoopMotionState.obscured(windows)
        if windowObscured != now { windowObscured = now }
    }
    #endif

    /// One app window's contribution to the gate. A struct so the decision is tested over a LIST (e.g. app window hidden while the status-item window is on screen, which was misread, #2397).
    struct WindowVisibility: Equatable {
        /// Visible AND not fully occluded: what `isVisible && occlusionState.contains(.visible)` answers.
        let onScreen: Bool
    }

    /// Pure half of the recompute, testable without AppKit. Takes already-filtered titled app windows; obscured means there are app windows and none is on screen.
    /// No windows is deliberately NOT obscured (launch, or window closed with Zoop running as a menu-bar app): treating it as obscured would pose static gauges until the next notification.
    /// That is only safe while the filter is state-independent, hence `.titled` (#2394/#2397). `nonisolated` so tests can call it off the main actor.
    nonisolated static func obscured(_ windows: [WindowVisibility]) -> Bool {
        !windows.isEmpty && !windows.contains { $0.onScreen }
    }

    /// The gate. `reduceMotion` comes from `@Environment(\.accessibilityReduceMotion)` at the call site; only the environment invalidates the view when the setting changes.
    ///
    /// ```swift
    /// @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// @ObservedObject private var motion = ZoopMotionState.shared
    /// private var poseStill: Bool { motion.poseStill(reduceMotion) }
    /// ```
    @inline(__always)
    public func poseStill(_ reduceMotion: Bool) -> Bool {
        reduceMotion || isLowPower || quietMotion || windowObscured
    }

}

// MARK: - CountUpText
// Counts a number up or down on change and on first appear (0 → value). A custom `Animatable` keeps it working on the iOS 16 / macOS 13 floor and it rides the
// environment's animation (default `ZoopMotion.value`). Quiet motion shows the final value instantly.

/// A text view whose number animates from its previous value to the new one; for big scores and hero read-outs.
///
/// ```swift
/// CountUpText(value: score,
///             format: { "\(Int($0.rounded()))" },
///             font: StrandFont.display(72),
///             color: StrandPalette.textPrimary)
///     .tracking(StrandFont.displayTracking(72))
/// ```
public struct CountUpText: View {
    private let value: Double
    private let format: (Double) -> String
    private let font: Font
    private let color: Color
    private let animation: Animation

    /// The value currently animated TO; on appear the run starts from 0.
    @State private var target: Double = 0
    @State private var hasAppeared = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // The system flag alone misses Zoop's own preference and Low Power Mode; use the shared gate so a refresh cannot restart suppressed work.
    @ObservedObject private var motion = ZoopMotionState.shared
    private var poseStill: Bool { motion.poseStill(reduceMotion) }

    /// - Parameters:
    ///   - value: the number to display / animate to.
    ///   - format: maps the (interpolated) number to its display string — round, clamp, add units here.
    ///   - font: the text font (e.g. `StrandFont.display(72)`).
    ///   - color: the text colour (e.g. `StrandPalette.textPrimary`).
    ///   - animation: the count-up curve. Defaults to `ZoopMotion.value`.
    public init(value: Double,
                format: @escaping (Double) -> String,
                font: Font,
                color: Color,
                animation: Animation = ZoopMotion.value) {
        self.value = value
        self.format = format
        self.font = font
        self.color = color
        self.animation = animation
    }

    public var body: some View {
        _AnimatableNumber(number: target, format: format, font: font, color: color)
            .onAppear {
                guard !hasAppeared else { return }
                hasAppeared = true
                if poseStill {
                    target = value                      // snap, no tick
                } else {
                    target = 0
                    withAnimation(animation) { target = value }
                }
            }
            .onChangeCompat(of: value) { newValue in
                if poseStill {
                    var tx = Transaction(); tx.disablesAnimations = true
                    withTransaction(tx) { target = newValue }
                } else {
                    withAnimation(animation) { target = newValue }
                }
            }
            // Single stable VoiceOver label; the ticking is decorative.
            .accessibilityElement()
            .accessibilityLabel(Text(format(value)))
    }
}

/// Animatable view: SwiftUI interpolates `number` per frame under the wrapping animation and `body` re-renders `format(number)`. A View (not the deprecated
/// `AnimatableModifier`) stays warning-clean on iOS 17 while compiling on the iOS 16 floor.
private struct _AnimatableNumber: View, Animatable {
    var number: Double
    let format: (Double) -> String
    let font: Font
    let color: Color

    var animatableData: Double {
        get { number }
        set { number = newValue }
    }

    var body: some View {
        Text(format(number))
            .font(font)
            .foregroundStyle(color)
            .fixedSize()                                // never truncate the number
            .accessibilityHidden(true)                  // CountUpText supplies the a11y label
    }
}

// MARK: - Staggered appear
// Fade-in + 8pt rise by `index`, once per element (`hasAppeared`) so re-renders and scroll recycling don't retrigger. Quiet motion → visible instantly.

private struct StaggeredAppear: ViewModifier {
    let index: Int
    let isVisible: Bool

    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Lazy sections re-enter while scrolling; quiet motion must show the final pose rather than schedule another delayed entrance.
    @ObservedObject private var motion = ZoopMotionState.shared
    private var poseStill: Bool { motion.poseStill(reduceMotion) }

    func body(content: Content) -> some View {
        let shown = hasAppeared || poseStill
        content
            .opacity(isVisible ? (shown ? 1 : 0) : 1)
            .offset(y: (isVisible && !shown) ? ZoopMotion.riseOffset : 0)
            .onAppear {
                guard isVisible, !hasAppeared else { return }
                if poseStill {
                    hasAppeared = true                  // no animation, no delay
                } else {
                    let delay = Double(max(0, index)) * ZoopMotion.stagger
                    withAnimation(ZoopMotion.card.delay(delay)) {
                        hasAppeared = true
                    }
                }
            }
            .onChangeCompat(of: poseStill) { if $0 { hasAppeared = true } }
    }
}

public extension View {
    /// Fade-in + 8pt rise on first appearance, delayed `index * 0.04s`, once per element. Quiet motion shows it instantly.
    ///
    /// - Parameters:
    ///   - index: position in the sequence (0 = first / no delay).
    ///   - isVisible: set `false` to opt an element out of the animation (it stays fully shown).
    func staggeredAppear(index: Int, isVisible: Bool = true) -> some View {
        modifier(StaggeredAppear(index: index, isVisible: isVisible))
    }
}

// MARK: - Soft card transition
// Card insert/remove inside an animated container: opacity + 0.98 scale, asymmetric so an inserted card grows in and a removed one fades out. Reduce Motion → plain fade.

public extension AnyTransition {
    /// The house card insert/remove transition; pass `reduced:` from `accessibilityReduceMotion` to degrade to a fade.
    static func softCard(reduced: Bool) -> AnyTransition {
        if reduced {
            return .opacity
        }
        let insertion = AnyTransition.opacity.combined(with: .scale(scale: 0.98, anchor: .center))
        let removal = AnyTransition.opacity.combined(with: .scale(scale: 0.98, anchor: .center))
        return .asymmetric(insertion: insertion, removal: removal)
    }
}

private struct SoftCardTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.transition(.softCard(reduced: reduceMotion))
    }
}

public extension View {
    /// Applies the house card transition, wired to Reduce Motion. Drive with `ZoopMotion.card`.
    func softCardTransition() -> some View {
        modifier(SoftCardTransition())
    }
}

// MARK: - Preview

#if DEBUG
private struct ZoopMotionDemo: View {
    @State private var score: Double = 72
    @State private var revealKey = 0
    @State private var cards: [Int] = [0, 1, 2]
    private let labels = ["SLEEP", "RECOVERY", "STRAIN", "HRV", "RHR", "CALORIES"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {

                // CountUpText — the big score ticks to a new value.
                VStack(alignment: .leading, spacing: 8) {
                    Text("COUNT-UP SCORE").strandOverline()
                    CountUpText(value: score,
                                format: { "\(Int($0.rounded()))" },
                                font: StrandFont.display(72),
                                color: StrandPalette.textPrimary)
                        .tracking(StrandFont.displayTracking(72))
                    Button("Roll the number") {
                        withAnimation(ZoopMotion.value) {
                            score = Double(Int.random(in: 12...99))
                        }
                    }
                    .foregroundStyle(StrandPalette.accent)
                }

                Divider().overlay(StrandPalette.hairline)

                // staggeredAppear — a list ripples in. `id` reset replays it.
                VStack(alignment: .leading, spacing: 8) {
                    Text("STAGGERED APPEAR").strandOverline()
                    VStack(spacing: 10) {
                        ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                            HStack {
                                Text(label).font(StrandFont.headline)
                                Spacer()
                                Text("\(42 + i * 7)").font(StrandFont.number(20))
                            }
                            .foregroundStyle(StrandPalette.textPrimary)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(ZoopPanelSurface(cornerRadius: 14))
                            .staggeredAppear(index: i)
                        }
                    }
                    .id(revealKey)
                    Button("Replay reveal") { revealKey += 1 }
                        .foregroundStyle(StrandPalette.accent)
                }

                Divider().overlay(StrandPalette.hairline)

                // softCardTransition — insert/remove.
                VStack(alignment: .leading, spacing: 8) {
                    Text("SOFT CARD TRANSITION").strandOverline()
                    VStack(spacing: 10) {
                        ForEach(cards, id: \.self) { c in
                            Text("Card \(c)")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                                .background(ZoopPanelSurface(cornerRadius: 14))
                                .softCardTransition()
                        }
                    }
                    HStack {
                        Button("Add") {
                            withAnimation(ZoopMotion.card) { cards.append((cards.max() ?? -1) + 1) }
                        }
                        Button("Remove") {
                            withAnimation(ZoopMotion.card) { if !cards.isEmpty { cards.removeLast() } }
                        }
                    }
                    .foregroundStyle(StrandPalette.accent)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 420, height: 720)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
    }
}

#Preview("ZoopMotion") { ZoopMotionDemo() }
#endif
