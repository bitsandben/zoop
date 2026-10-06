import SwiftUI

// MARK: - NOOP visual foundation
//
// These tokens describe the visual treatment used by NOOP's existing views. They deliberately
// contain no navigation, state, or domain semantics: screens keep their current hierarchy and data
// bindings, while cards, gauges, typography, and chrome share one maintainable source of truth.

public enum ZoopVisualStyle {
    // Dark mode follows the WHOOP reference: a cool slate canvas, flat charcoal cards with no rim,
    // and near-white type. Values are sampled from the supplied reference screenshots.
    public static let canvas = Color(light: "#F3F4F6", dark: "#121619")
    public static let surface = Color(light: "#FFFFFF", dark: "#272B2F")
    public static let surfaceTop = Color(light: "#FFFFFF", dark: "#2B3034")
    public static let surfaceBottom = Color(light: "#F4F5F7", dark: "#25292D")
    public static let inset = Color(light: "#E8E9ED", dark: "#1E2225")

    public static let border = Color(light: "#D8DAE0", dark: "#33383C")
    public static let borderHighlight = Color(light: "#FFFFFF", dark: "#3C4247")
    public static let divider = Color(light: "#E4E5E9", dark: "#353B40")

    public static let primaryText = Color(light: "#17181C", dark: "#F2F7FA")
    public static let secondaryText = Color(light: "#555861", dark: "#A9B1B7")
    public static let tertiaryText = Color(light: "#7D808A", dark: "#737C83")

    public static let mint = Color(light: "#00A86F", dark: "#00F19F")
    public static let mintDeep = Color(light: "#008257", dark: "#00B377")
    public static let mintGlow = Color(light: "#00C985", dark: "#00F19F")

    public static let cardRadius: CGFloat = 18
    public static let compactRadius: CGFloat = 16
    public static let pillRadius: CGFloat = 999
    public static let pagePadding: CGFloat = 16
    public static let cardPadding: CGFloat = 16
    public static let itemGap: CGFloat = 12
    public static let sectionGap: CGFloat = 26
}

/// Shared card/panel treatment: a solid surface on iOS, gradient and soft elevation elsewhere.
/// `tint` is intentionally faint so metric identity never turns the whole card into a coloured tile.
public struct ZoopPanelSurface: View {
    public var tint: Color?
    public var cornerRadius: CGFloat
    public var elevated: Bool
    public var surfaceOpacity: Double
    #if !os(iOS)
    @Environment(\.colorScheme) private var scheme
    #endif

    public init(
        tint: Color? = nil,
        cornerRadius: CGFloat = ZoopVisualStyle.cardRadius,
        elevated: Bool = false,
        surfaceOpacity: Double = 1
    ) {
        self.tint = tint
        self.cornerRadius = cornerRadius
        self.elevated = elevated
        self.surfaceOpacity = surfaceOpacity
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if os(iOS)
        // Scrolling stacks contain many panels. Layered translucent gradients and blurred shadows
        // multiply their compositing work, so iOS uses one theme-aware fill and a thin tinted rim.
        // This changes decorative depth only; card geometry and the design-system colors stay the same.
        // WHOOP-style cards carry no rim: a flat charcoal fill on the slate canvas.
        shape
            .fill(ZoopVisualStyle.surface)
            .opacity(surfaceOpacity)
        #else
        shape
            .fill(
                LinearGradient(
                    colors: [ZoopVisualStyle.surfaceTop, ZoopVisualStyle.surfaceBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                if let tint {
                    shape.fill(
                        LinearGradient(
                            colors: [tint.opacity(0.055), tint.opacity(0.012), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [ZoopVisualStyle.borderHighlight.opacity(0.72), ZoopVisualStyle.border.opacity(0.52)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
            )
            .shadow(
                color: scheme == .dark ? .black.opacity(elevated ? 0.34 : 0.18) : .black.opacity(0.10),
                radius: elevated ? 18 : 9,
                x: 0,
                y: elevated ? 10 : 5
            )
            .opacity(surfaceOpacity)
        #endif
    }
}

/// Shared edge-to-edge chrome for sheet and split-view headers. Unlike a card it has no
/// rounded outline or elevation, but it uses the same top-lit surface ramp and divider token.
public struct ZoopChromeSurface: View {
    public init() {}

    public var body: some View {
        LinearGradient(
            colors: [ZoopVisualStyle.surfaceTop, ZoopVisualStyle.surfaceBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ZoopVisualStyle.divider)
                .frame(height: 0.5)
        }
    }
}

public extension View {
    func noopPanel(
        tint: Color? = nil,
        cornerRadius: CGFloat = ZoopVisualStyle.cardRadius,
        elevated: Bool = false,
        surfaceOpacity: Double = 1
    ) -> some View {
        background {
            ZoopPanelSurface(
                tint: tint,
                cornerRadius: cornerRadius,
                elevated: elevated,
                surfaceOpacity: surfaceOpacity
            )
        }
    }
}
