import SwiftUI

// MARK: - Frosted card surface
//
// The card surface: `ZoopPanelSurface` plus the user's "Card transparency" setting. Internal: app code
// reaches it only through the card types (`ContentCard`, `HeroCard`, `ListCard`, `ZoopCard`) or the
// `zoopInsetSurface` / `zoopControlSurface` modifiers.

/// The frosted-card background fill and border. Standalone so it can be a
/// `.background { }` (animation never reaches the card's content subtree — #104).
struct FrostedCardSurface: View {
    var tint: Color?
    var cornerRadius: CGFloat
    var washStrength: Double
    // "Card transparency" setting (reactive): fades the whole glass surface toward the background. 100 =
    // solid (default). Reading it here makes every card update live when the Settings slider moves.
    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent

    init(tint: Color? = nil, cornerRadius: CGFloat = 22, washStrength: Double = 1.0) {
        self.tint = tint
        self.cornerRadius = cornerRadius
        self.washStrength = washStrength
    }

    var body: some View {
        let op = max(0.0, min(1.0, Double(cardOpacityPercent) / 100.0))
        ZoopPanelSurface(
            tint: tint?.opacity(washStrength),
            cornerRadius: cornerRadius,
            elevated: false,
            surfaceOpacity: op
        )
    }
}

// MARK: - Touch press feedback (iOS) — the hover lift's touch analogue.
//
// `.onHover` never fires on a touchscreen, so tappable cards/rows feel dead on iPhone.
// This gives a subtle press-DOWN state (scale + edge emphasis) for direct manipulation,
// honouring Reduce Motion (which swaps the transform for a gentle dim). It's additive to
// the hover lift: hover (pointer NEAR) and pressed (finger/click DOWN) animate distinct
// properties on the shared StrandMotion.interactive spring, so they compose without a
// double-bounce. Exposed two ways — a ButtonStyle for Button/NavigationLink-as-card (the
// `.plain` replacement), and a `.strandPressable()` modifier for `.onTapGesture`-driven cards.

/// Drop-in replacement for `.buttonStyle(.plain)` on full-card Buttons / NavigationLinks:
/// a subtle press-down scale + hairline-strong edge.
public struct StrandPressableButtonStyle: ButtonStyle {
    public var cornerRadius: CGFloat
    public var scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(cornerRadius: CGFloat = ZoopMetrics.cardRadius, scale: CGFloat = 0.985) {
        self.cornerRadius = cornerRadius
        self.scale = scale
    }

    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .scaleEffect(reduceMotion ? 1 : (pressed ? scale : 1))
            .opacity(reduceMotion && pressed ? 0.82 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1)
                    .opacity(pressed ? 1 : 0)
            )
            .animation(StrandMotion.interactive, value: pressed)
            .contentShape(Rectangle())
    }
}

/// Backs `.strandPressable()` — a press-down state for cards driven by `.onTapGesture`
/// (no Button). A 0-distance drag tracks the finger; @GestureState auto-resets on release
/// or when a parent scroll claims the gesture.
public struct StrandPressableModifier: ViewModifier {
    public var cornerRadius: CGFloat
    public var scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var pressed = false

    public init(cornerRadius: CGFloat = ZoopMetrics.cardRadius, scale: CGFloat = 0.985) {
        self.cornerRadius = cornerRadius
        self.scale = scale
    }

    public func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion ? 1 : (pressed ? scale : 1))
            .opacity(reduceMotion && pressed ? 0.82 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1)
                    .opacity(pressed ? 1 : 0)
            )
            .animation(StrandMotion.interactive, value: pressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, state, _ in state = true }
            )
    }
}

public extension View {
    /// Subtle touch press-down feedback for a tappable card/row that uses `.onTapGesture`
    /// (not a Button). For Buttons/NavigationLinks, use `StrandPressableButtonStyle` instead.
    func strandPressable(cornerRadius: CGFloat = ZoopMetrics.cardRadius, scale: CGFloat = 0.985) -> some View {
        modifier(StrandPressableModifier(cornerRadius: cornerRadius, scale: scale))
    }
}
