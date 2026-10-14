import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - ZoopType: the six semantic type tokens (Zoop 2.0 §7.1)
//
// The ONLY sizes a 2.0 screen may use. Every token scales with Dynamic Type, and both themes expose
// the same six names, so a view never branches on the theme: Classic keeps the square default face,
// Pastel & Nature swaps to SF Rounded where the table asks for it. Additive: the older `StrandFont`
// scale keeps working until the call sites are migrated.

public enum ZoopType {

    /// Hero number. 56 bold tabular (Classic) / 56 semibold rounded (Pastel); scales relative to `.largeTitle`.
    public static var display: Font {
        scaled(56, weight: ZoopTheme.isPastel ? .semibold : .bold, style: .largeTitle).monospacedDigit()
    }

    /// Navigation large title.
    public static var title: Font {
        Font.system(.largeTitle, design: design, weight: .bold)
    }

    /// Tile / row value. 28 semibold tabular; scales relative to `.title`.
    public static var metric: Font {
        scaled(28, weight: .semibold, style: .title).monospacedDigit()
    }

    /// Card title / section header.
    public static var headline: Font {
        Font.system(.headline, design: design)
    }

    /// The one-sentence meaning line. Never themed: body copy keeps the default face.
    public static var body: Font { Font.system(.body) }

    /// Units, deltas, data age.
    public static var caption: Font { Font.system(.footnote) }

    // Why: Classic = default design, Pastel = rounded, for the tokens the table marks as themed.
    private static var design: Font.Design { ZoopTheme.isPastel ? .rounded : .default }

    /// A fixed point size that still follows Dynamic Type (`Font.system(size:)` does not scale).
    private static func scaled(_ size: CGFloat, weight: Font.Weight, style: Font.TextStyle) -> Font {
        #if canImport(UIKit) && !os(watchOS)
        let base = UIFont.systemFont(ofSize: size, weight: weight.uiWeight)
        let face = design == .rounded
            ? base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
            : base
        let uiStyle: UIFont.TextStyle = style == .largeTitle ? .largeTitle : .title1
        return Font(UIFontMetrics(forTextStyle: uiStyle).scaledFont(for: face))
        #else
        return Font.system(size: size, weight: weight, design: design)
        #endif
    }
}

#if canImport(UIKit) && !os(watchOS)
private extension Font.Weight {
    var uiWeight: UIFont.Weight {
        switch self {
        case .bold: return .bold
        case .semibold: return .semibold
        case .medium: return .medium
        default: return .regular
        }
    }
}
#endif

// MARK: - Spacing and radius (§7.2)

/// 4-pt grid.
public enum ZoopSpacing {
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32

    /// Screen gutter and card padding.
    public static let gutter: CGFloat = 16
    public static let cardPadding: CGFloat = 16
    /// Between cards / between sections.
    public static let cardGap: CGFloat = 12
    public static let sectionGap: CGFloat = 24
}

/// Continuous corner radii. Sheets use the system radius.
public enum ZoopRadius {
    public static let card: CGFloat = 24
    public static let tile: CGFloat = 18
    public static let button: CGFloat = 14
}
