import SwiftUI

// MARK: - ZoopButton — the unified button system
// One button, four kinds, no glow: crisp filled accent, honest surface fills, subtle press. Colours are `StrandPalette` tokens, dimensions `ZoopMetrics`.
// Entry points: `ZoopButton("Save", kind: .primary) { … }`, or `.buttonStyle(ZoopButtonStyle(.primary))` to adopt on an existing Button (e.g. a Menu/role button).
// Labels are sentence-case, single line, icon and word as one unit; under Reduce Motion the press scale drops and only the dim remains.

/// The four button roles. Colour + emphasis differ; geometry is identical across all four.
public enum ZoopButtonKind: Sendable {
    /// Filled accent (blue), white label — the one primary action on a screen.
    case primary
    /// Raised-surface fill, primary-text label, hairline edge — secondary actions.
    case secondary
    /// No fill, accent label — low-emphasis / inline actions.
    case tertiary
    /// Filled critical (red), white label — destructive / irreversible actions.
    case destructive
}

// MARK: - Shared geometry / resolved styling

/// Fixed geometry shared by the view and the ButtonStyle so both paths are pixel-identical.
public enum ZoopButtonMetrics {
    /// Standard control height (48) — also the source for the min hit target floor.
    public static let height: CGFloat = ZoopMetrics.controlHeight
    /// Corner radius (14) — softer than a card, not a pill.
    public static let cornerRadius: CGFloat = 14
    /// Horizontal label inset.
    public static let hPadding: CGFloat = 18
    /// Spacing between a leading icon and the label.
    public static let iconSpacing: CGFloat = 8
    /// Label tracking — a hair of openness on the semibold face.
    public static let tracking: CGFloat = 0.2
    /// Apple's minimum touch target. The button never reports a hit area below this.
    public static let minHitTarget: CGFloat = 44
    /// Pressed scale (spec: subtle 0.97). Reduce-Motion collapses this to 1 (dim only).
    public static let pressedScale: CGFloat = 0.97
    /// Pressed dim — a slight opacity drop, applied in BOTH motion modes.
    public static let pressedOpacity: Double = 0.82
    /// Disabled dim, shared so call sites don't invent their own.
    public static let disabledOpacity: Double = 0.4
}

/// Resolves a `ZoopButtonKind` to its fill / label / border tokens, shared by style and view.
struct ZoopButtonAppearance {
    let fill: Color?          // nil = no fill (tertiary)
    let label: Color
    let border: Color?        // nil = no hairline edge
    let usesPanelSurface: Bool

    init(_ kind: ZoopButtonKind) {
        switch kind {
        case .primary:
            #if os(iOS)
            // The redesign's primary action is a white control with dark text.
            fill = StrandPalette.primaryButtonFill
            label = StrandPalette.primaryButtonText
            #else
            fill = StrandPalette.accent
            label = StrandPalette.goldDeepText   // designated crisp white for text on accent fills
            #endif
            border = nil
            usesPanelSurface = false
        case .secondary:
            #if os(iOS)
            // The panel surface is the card colour, so on a card the button vanished; its own fill and
            // hairline keep it visible on cards and canvas alike.
            fill = StrandPalette.secondaryButtonFill
            label = StrandPalette.secondaryButtonText
            border = StrandPalette.secondaryButtonBorder
            usesPanelSurface = false
            #else
            fill = nil
            label = StrandPalette.textPrimary
            border = nil
            usesPanelSurface = true
            #endif
        case .tertiary:
            fill = nil
            #if os(iOS)
            label = StrandPalette.textPrimary
            #else
            label = StrandPalette.accent
            #endif
            border = nil
            usesPanelSurface = false
        case .destructive:
            fill = StrandPalette.statusCritical
            label = StrandPalette.goldDeepText   // crisp white on the critical fill
            border = nil
            usesPanelSurface = false
        }
    }
}

// MARK: - The crisp background (no glow, ever)

/// The flat, glow-free button background: a filled (or unfilled) rounded rect with an
/// optional hairline edge. No shadow, no blur halo, no additive bloom — restraint only.
private struct ZoopButtonBackground: View {
    let appearance: ZoopButtonAppearance

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ZoopButtonMetrics.cornerRadius, style: .continuous)
        ZStack {
            if appearance.usesPanelSurface {
                ZoopPanelSurface(cornerRadius: ZoopButtonMetrics.cornerRadius)
            }
            if let fill = appearance.fill {
                shape.fill(fill)
            }
            if let border = appearance.border {
                shape.strokeBorder(border, lineWidth: 1)
            }
        }
    }
}

// MARK: - ButtonStyle (adopt on any existing Button)

/// Apply the Zoop button look to ANY `Button` (e.g. a role/`Menu` button). Under Reduce Motion the press scale drops to dim-only. Pixel-identical to `ZoopButton`.
public struct ZoopButtonStyle: ButtonStyle {
    private let kind: ZoopButtonKind
    private let fullWidth: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    public init(_ kind: ZoopButtonKind = .primary, fullWidth: Bool = false) {
        self.kind = kind
        self.fullWidth = fullWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        let appearance = ZoopButtonAppearance(kind)
        let pressed = configuration.isPressed
        // Reduce Motion: no scale, dim only. Otherwise subtle scale + dim.
        let scale: CGFloat = (pressed && !reduceMotion) ? ZoopButtonMetrics.pressedScale : 1
        let opacity: Double = pressed ? ZoopButtonMetrics.pressedOpacity : 1

        configuration.label
            .labelStyle(.titleAndIcon)
            .font(StrandFont.headline.weight(.semibold))
            .tracking(ZoopButtonMetrics.tracking)
            .lineLimit(1)
            .minimumScaleFactor(0.9)
            .foregroundStyle(appearance.label)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, ZoopButtonMetrics.hPadding)
            .frame(height: ZoopButtonMetrics.height)
            .frame(minHeight: ZoopButtonMetrics.minHitTarget)
            .contentShape(Rectangle())
            .background(ZoopButtonBackground(appearance: appearance))
            .clipShape(RoundedRectangle(cornerRadius: ZoopButtonMetrics.cornerRadius, style: .continuous))
            .opacity(isEnabled ? opacity : ZoopButtonMetrics.disabledOpacity)
            .scaleEffect(scale)
            .animation(reduceMotion ? nil : StrandMotion.interactive, value: pressed)
    }
}

// MARK: - ZoopButton (the convenience view)

/// The unified button: a sentence-case title, optional leading SF Symbol, a `ZoopButtonKind`, optional `fullWidth`, and an action. Flat, 44pt hit floor, Reduce-Motion aware.
///
/// ```swift
/// ZoopButton("Save changes", systemImage: "checkmark", kind: .primary, fullWidth: true) {
///     save()
/// }
/// ```
public struct ZoopButton: View {
    private let title: LocalizedStringKey
    private let systemImage: String?
    private let kind: ZoopButtonKind
    private let fullWidth: Bool
    private let action: () -> Void

    public init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        kind: ZoopButtonKind = .primary,
        fullWidth: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.kind = kind
        self.fullWidth = fullWidth
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            // The ButtonStyle owns the chrome; the label is just icon + word as one centred unit at the 8pt token spacing (no phantom gap without an icon).
            HStack(spacing: ZoopButtonMetrics.iconSpacing) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .imageScale(.medium)  // optically centres to the cap height of the label
                }
                Text(title)
            }
        }
        .buttonStyle(ZoopButtonStyle(kind, fullWidth: fullWidth))
    }
}

#if DEBUG
#Preview("ZoopButton") {
    ScrollView {
        VStack(spacing: ZoopMetrics.rowSpacing) {
            ZoopButton("Primary action", systemImage: "checkmark", kind: .primary) {}
            ZoopButton("Secondary action", systemImage: "square.and.arrow.up", kind: .secondary) {}
            ZoopButton("Tertiary action", kind: .tertiary) {}
            ZoopButton("Delete recording", systemImage: "trash", kind: .destructive) {}

            Divider().overlay(StrandPalette.hairline)

            ZoopButton("Full-width primary", systemImage: "bolt.fill", kind: .primary, fullWidth: true) {}
            ZoopButton("Full-width secondary", kind: .secondary, fullWidth: true) {}

            Button("Adopted via ZoopButtonStyle") {}
                .buttonStyle(ZoopButtonStyle(.secondary, fullWidth: true))

            ZoopButton("Disabled", kind: .primary) {}
                .disabled(true)
        }
        .screenPadding()
        .padding(.vertical, ZoopMetrics.space6)
    }
    .frame(width: 380, height: 560)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
