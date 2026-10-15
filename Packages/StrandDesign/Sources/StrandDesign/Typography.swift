import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Strand Typography
// SF Pro for text and condensed bold SF Pro for numerals; all numeric styles use `.monospacedDigit()` so live values don't reflow.
// Named text styles keep Dynamic Type scaling. SF Mono is reserved for logs.

public enum StrandFont {

    // MARK: Family

    /// The display face: SF Rounded under Pastel & Nature, the square default face otherwise.
    /// Body copy never changes face; only numbers and headings follow the theme.
    static var displayDesign: Font.Design { ZoopTheme.isPastel ? .rounded : .default }

    private static func roundedSystem(_ size: CGFloat, weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: displayDesign)
    }

    /// Condensed numerals: the narrow, tall figure the reference uses for scores and readings.
    /// Pastel & Nature uses the full-width rounded figure instead (SF Rounded has no condensed width).
    private static func numeralSystem(_ size: CGFloat, weight: Font.Weight) -> Font {
        ZoopTheme.isPastel
            ? .system(size: size, weight: weight, design: .rounded)
            : .system(size: size, weight: weight, design: .default).width(.condensed)
    }

    // MARK: Scale

    /// Display 64–80 / Bold, the gauge score number: Helvetica Neue 700, tight tracking, tabular digits.
    public static func display(_ size: CGFloat = 72) -> Font {
        numeralSystem(size, weight: .bold).monospacedDigit()
    }

    /// Tight tracking for big display numbers (≈ -0.04em); apply with `display(_:)`, e.g. `.tracking(StrandFont.displayTracking(72))`.
    public static func displayTracking(_ size: CGFloat = 72) -> CGFloat {
        -size * 0.04
    }

    /// Helvetica-Neue numeric style at any size/weight, the house numeral; tabular so live values align.
    public static func rounded(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        roundedSystem(size, weight: weight).monospacedDigit()
    }

    /// A heading at a fixed size/weight in the theme's display face (plain system under Classic, SF Rounded under Pastel & Nature).
    /// Use instead of hard-coded `.system(size:weight:)`; body copy stays put.
    public static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        roundedSystem(size, weight: weight)
    }

    /// Title1 28 / Bold. Scales with Dynamic Type.
    public static var title1: Font { Font.system(.title, design: displayDesign, weight: .bold) }

    /// Title2 22 / Semibold. Scales with Dynamic Type.
    public static var title2: Font { Font.system(.title2, design: displayDesign, weight: .bold) }

    /// Headline 17 / Semibold. Scales with Dynamic Type.
    public static var headline: Font { Font.system(.headline, design: displayDesign, weight: .semibold) }

    /// Body 15 / Regular. Scales with Dynamic Type.
    public static let body = Font.system(.body, design: .default, weight: .regular)

    /// Subhead 13. Scales with Dynamic Type.
    public static let subhead = Font.system(.subheadline, design: .default, weight: .regular)

    /// Caption 12. Scales with Dynamic Type.
    public static let caption = Font.system(.caption, design: .default, weight: .regular)

    /// Footnote 11. Scales with Dynamic Type.
    public static let footnote = Font.system(.footnote, design: .default, weight: .regular)

    /// Overline 11 / Bold, +1.4 tracking (`overlineText(_:)` applies it); sparing ALL-CAPS labels. Scales with Dynamic Type.
    /// Also the face for compact status copy in constrained chrome (the Today sync capsule), used there WITHOUT tracking since that is sentence case.
    public static let overline = Font.system(.footnote, design: .default, weight: .semibold)

    /// `overline` at a custom point size, same face, weight and Dynamic-Type scaling (11 returns exactly `.overline`); shrinks an ALL-CAPS label to fit without losing text scaling.
    public static func overlineScaled(_ size: CGFloat) -> Font {
        #if canImport(UIKit)
        let base = UIFont.systemFont(ofSize: size, weight: .bold)
        return Font(UIFontMetrics(forTextStyle: .caption2).scaledFont(for: base))
        #elseif canImport(AppKit)
        return Font(NSFont.systemFont(ofSize: size, weight: .bold))
        #else
        return roundedSystem(size, weight: .bold)
        #endif
    }

    /// Mono 13 (SF Mono) — raw / log views. Tabular by nature.
    public static let mono = Font.system(size: 13, weight: .regular, design: .monospaced)

    // MARK: Numeric variants (tabular digits)

    /// Numeric style at any size/weight for live values (Helvetica Neue, tabular): the tile/value numeral.
    public static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        numeralSystem(size, weight: weight).monospacedDigit()
    }

    /// Helvetica-Neue body number for inline live values; scales with Dynamic Type alongside its labels.
    public static var bodyNumber: Font { Font.system(.body, design: displayDesign, weight: .medium).monospacedDigit() }

    /// Helvetica-Neue caption number — for small live values (sparklines, chips). Scales with Dynamic Type.
    public static var captionNumber: Font { Font.system(.caption, design: displayDesign, weight: .medium).monospacedDigit() }

    /// Mono at an arbitrary size.
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// The recommended tracking for overline text (wide ALL-CAPS labels, ≈ 0.13em).
    public static let overlineTracking: CGFloat = 0
}

// MARK: - Text helpers

public extension Text {
    /// Small label: semibold, secondary text, sentence case (no case transform).
    func strandOverline() -> some View {
        self.font(StrandFont.overline)
            .tracking(StrandFont.overlineTracking)
            .foregroundStyle(StrandPalette.textSecondary)
    }
}

public extension View {
    /// Convenience: an overline-styled label string.
    static func strandOverline(_ string: String) -> some View {
        Text(string).strandOverline()
    }
}

#if DEBUG
#Preview("Typography") {
    ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Text("88").font(StrandFont.display(72)).tracking(StrandFont.displayTracking(72)).foregroundStyle(StrandPalette.textPrimary)
            Text("Title 1 / Bold 28").font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)
            Text("Title 2 / Semibold 22").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text("Headline / Semibold 17").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Text("Body / Regular 15 — the thread of you, read in full.")
                .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
            Text("Subhead 13").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Text("Caption 12").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            Text("Footnote 11").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Text("Overline").strandOverline()
            Text("0xAA 41 00 1c crc32=f3a1  mono 13").font(StrandFont.mono).foregroundStyle(StrandPalette.textSecondary)
            HStack(spacing: 4) {
                Text("HRV").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                Text("62").font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                Text("ms").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 520, height: 620)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
