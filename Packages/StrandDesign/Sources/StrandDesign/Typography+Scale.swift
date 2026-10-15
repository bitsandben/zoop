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

    // MARK: Supporting tokens (the migration off `.font(.system(size:))`)
    //
    // Chrome that the six tokens above do not cover. Each one still scales with Dynamic Type except
    // `icon`, whose glyph sits in fixed-size chrome. Add `.weight(_:)` / `.monospacedDigit()` at the
    // use site rather than inventing another size.

    /// 9–11 pt labels: chart axis ticks, legend keys, tiny badges, unit suffixes on small readouts.
    public static var micro: Font { Font.system(.caption2) }

    /// 12 pt secondary labels in dense rows and chips.
    public static var small: Font { Font.system(.caption) }

    /// 14–15 pt row and button labels.
    public static var label: Font { Font.system(.subheadline) }

    /// 16 pt emphasised row text and compact button titles.
    public static var callout: Font { Font.system(.callout) }

    /// 18–22 pt text headings inside a card or sheet (not numbers; those use `number(_:)`).
    public static var subtitle: Font { Font.system(.title3, design: design) }

    /// A number at a fixed point size in the theme's numeral face (tabular digits): ring centres,
    /// secondary heroes and readouts that sit between `metric` and `display`. Scales with Dynamic Type.
    public static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        scaled(size, weight: weight, style: size >= 34 ? .largeTitle : .title).monospacedDigit()
    }

    /// An SF Symbol glyph at a fixed point size. Symbols sit inside fixed chrome (wells, buttons,
    /// pills), so the size does not follow Dynamic Type; text never uses this.
    public static func icon(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight)
    }

    /// Monospaced text (raw values, codes, logs) at the footnote size.
    public static var mono: Font { Font.system(.footnote, design: .monospaced) }

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
