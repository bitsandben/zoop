import SwiftUI

/// Data-visualisation colour style: brand "Titanium & Gold" ramps, or the "Classic" red → amber → green
/// readiness scale. Re-colours DATA encodings only, never chrome. Read via `StrandPalette.chartStyle`;
/// the app root keys its content on the raw value so a flip re-renders live.
public enum ChartStyle: String, CaseIterable, Identifiable, Sendable {
    case titanium   // brand: gold recovery, amber strain, blue rest
    case classic    // throwback: red→green recovery, cool→hot zones, green→red stress

    public var id: String { rawValue }
    public static let storageKey = "chart.style"

    public var label: String {
        switch self {
        case .titanium: return String(localized: "Default", bundle: .module)
        case .classic:  return String(localized: "Classic", bundle: .module)
        }
    }

    public static func resolve(_ raw: String) -> ChartStyle { ChartStyle(rawValue: raw) ?? .titanium }
}

/// Sleep stage-chart shape: per-stage rows, or a single stepped hypnogram FILLED or as a slim RIBBON.
/// Display-only; Filled/Ribbon fall back to Classic on a night without timestamped segments.
/// Device-local (NOT in the `.zoopbak` whitelist).
public enum SleepChartStyle: String, CaseIterable, Identifiable, Sendable {
    case classic       // per-stage-rows timeline (the default, unchanged)
    case filled        // stepped hypnogram filled to the baseline, Zoop sleep colours
    case garminFilled  // the same filled chart in Garmin's blue/magenta ramp
    case ribbon        // slim band at each stage level, Oura's cream/blue ramp

    public var id: String { rawValue }
    public static let storageKey = "sleep.chart.style"

    public var label: String {
        switch self {
        case .classic:      return String(localized: "Classic", bundle: .module)
        case .filled:       return String(localized: "Fill", bundle: .module)
        case .garminFilled: return String(localized: "Garmin Fill", bundle: .module)
        case .ribbon:       return String(localized: "Ribbon", bundle: .module)
        }
    }

    /// Whether the stepped chart fills each stage to the baseline rather than drawing a ribbon.
    public var isFilled: Bool { self == .filled || self == .garminFilled }

    /// The stage-colour ramp this style draws with.
    public var stagePalette: SleepStagePalette {
        switch self {
        case .classic, .filled: return .noop
        case .garminFilled:     return .garmin
        case .ribbon:           return .oura
        }
    }

    public static func resolve(_ raw: String) -> SleepChartStyle { SleepChartStyle(rawValue: raw) ?? .classic }
}

/// Which stage-colour ramp a sleep chart draws with: Zoop's own, Oura's, or Garmin's.
public enum SleepStagePalette: String, Sendable { case noop, oura, garmin }

/// Sets the global `StrandPalette.chartStyle` and keys the content on the raw value so a flip
/// re-renders live. Apply at each app root.
public extension View {
    func chartStyle(_ raw: String) -> some View {
        StrandPalette.chartStyle = ChartStyle.resolve(raw)
        return self.id("zoop.chartStyle.\(raw)")
    }
}

/// The user's CHROME accent (buttons, links, focus rings, selected states); never the DATA colour
/// worlds (those follow `ChartStyle`). Read via `StrandPalette.accentChoice` / `customAccentHex`.
public enum AccentColor: String, CaseIterable, Identifiable, Sendable {
    case mint        // the brand default (#1068 ZoopVisualStyle.mint world)
    case whoopBlue   // the classic WHOOP link blue
    case custom      // a user-picked colour (hex stored separately)

    public var id: String { rawValue }
    public static let storageKey = "accent.color"
    /// Custom hex, stored separately so switching away from `.custom` and back keeps the choice.
    public static let customHexKey = "accent.customHex"
    /// Seeds the custom picker so a fresh `.custom` selection is not black.
    public static let defaultCustomHex = "#149A78"

    public var label: String {
        switch self {
        // Under Pastel & Nature the brand accent resolves to lavender, so the label follows.
        case .mint:      return ZoopTheme.isPastel ? String(localized: "Lavender", bundle: .module) : String(localized: "Mint", bundle: .module)
        case .whoopBlue: return String(localized: "WHOOP Blue", bundle: .module)
        case .custom:    return String(localized: "Custom", bundle: .module)
        }
    }

    public static func resolve(_ raw: String) -> AccentColor { AccentColor(rawValue: raw) ?? .mint }

    /// The chrome accent. `.custom` resolves the stored hex at read time.
    public var accent: Color {
        switch self {
        case .mint:      return ZoopVisualStyle.mint
        case .whoopBlue: return Color(light: "#234F9E", dark: "#60A0E0")
        case .custom:    return Color(hex: StrandPalette.customAccentHex)
        }
    }

    /// The brighter hover/pressed accent; for `.custom` the chosen colour lightened toward white.
    public var accentHover: Color {
        switch self {
        case .mint:      return ZoopVisualStyle.mintGlow
        case .whoopBlue: return Color(light: "#3A6FC0", dark: "#8FBEEC")
        case .custom:    return AccentColor.lighten(StrandPalette.customAccentHex)
        }
    }

    /// Low-opacity accent tint for muted fills; translucent so it composites over any surface.
    public var accentMuted: Color {
        switch self {
        case .mint:      return ZoopVisualStyle.mintDeep.opacity(0.18)
        case .whoopBlue: return Color(light: "#234F9E", dark: "#60A0E0").opacity(0.18)
        case .custom:    return Color(hex: StrandPalette.customAccentHex).opacity(0.18)
        }
    }

    public var focusRing: Color { accent }

    /// Blends an sRGB hex toward white by `amount` (0…1): the hover derivation for a custom accent.
    static func lighten(_ hex: String, by amount: Double = 0.24) -> Color {
        let c = Color.sRGBComponents(hex: hex)
        func up(_ x: Double) -> Double { min(1, x + (1 - x) * amount) }
        return Color(.sRGB, red: up(c.r), green: up(c.g), blue: up(c.b), opacity: 1)
    }
}

/// Sets `StrandPalette.accentChoice` + `customAccentHex` and keys the content so a change re-renders
/// live. Apply at each app root.
public extension View {
    func noopAccent(_ raw: String, customHex: String) -> some View {
        StrandPalette.accentChoice = AccentColor.resolve(raw)
        StrandPalette.customAccentHex = customHex
        return self.id("zoop.accent.\(raw).\(customHex)")
    }
}

/// A named THEME preset: a one-tap bundle of accent, chart colour world, day-cycle backdrop and card
/// opacity. There is no stored "current theme"; it is DERIVED from live prefs via `matching`, so
/// tweaking any control resolves to `.custom`. Theme MODE is independent and never bundled.
public enum ThemePreset: String, CaseIterable, Identifiable, Sendable {
    case mint       // brand default: mint accent, Titanium charts, backdrop on, solid cards
    case ocean      // WHOOP-blue accent, Titanium charts, backdrop on, solid
    case classic    // WHOOP-blue accent, Classic throwback charts, backdrop on, solid
    case midnight   // mint accent, Titanium charts, backdrop OFF (plain canvas), solid
    case frosted    // mint accent, Titanium charts, backdrop on, translucent cards
    case custom     // sentinel: the live combination matches no preset

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .mint:     return ZoopTheme.isPastel ? String(localized: "Lavender", bundle: .module) : String(localized: "Mint", bundle: .module)
        case .ocean:    return String(localized: "Ocean", bundle: .module)
        case .classic:  return String(localized: "Classic", bundle: .module)
        case .midnight: return String(localized: "Midnight", bundle: .module)
        case .frosted:  return String(localized: "Frosted", bundle: .module)
        case .custom:   return String(localized: "Custom", bundle: .module)
        }
    }

    /// The four values a preset writes (nil for `.custom`). Not named `Bundle`: that would shadow `Foundation.Bundle`.
    public struct Recipe: Sendable {
        public let accent: AccentColor
        public let chart: ChartStyle
        public let backdrop: Bool
        public let cardOpacity: Int
    }

    public var recipe: Recipe? {
        switch self {
        case .mint:     return Recipe(accent: .mint,      chart: .titanium, backdrop: true,  cardOpacity: 100)
        case .ocean:    return Recipe(accent: .whoopBlue, chart: .titanium, backdrop: true,  cardOpacity: 100)
        case .classic:  return Recipe(accent: .whoopBlue, chart: .classic,  backdrop: true,  cardOpacity: 100)
        case .midnight: return Recipe(accent: .mint,      chart: .titanium, backdrop: false, cardOpacity: 100)
        case .frosted:  return Recipe(accent: .mint,      chart: .titanium, backdrop: true,  cardOpacity: 85)
        case .custom:   return nil
        }
    }

    /// Presets a user can pick (everything except the derived `.custom`).
    public static var selectable: [ThemePreset] { allCases.filter { $0 != .custom } }

    public static func resolve(_ raw: String) -> ThemePreset { ThemePreset(rawValue: raw) ?? .mint }

    /// Which preset the live prefs correspond to, or `.custom` when none match.
    public static func matching(accent: AccentColor, chart: ChartStyle,
                                backdrop: Bool, cardOpacity: Int) -> ThemePreset {
        for p in selectable {
            if let r = p.recipe, r.accent == accent, r.chart == chart,
               r.backdrop == backdrop, r.cardOpacity == cardOpacity {
                return p
            }
        }
        return .custom
    }
}

/// The user's appearance preference, persisted via `@AppStorage(AppearanceMode.storageKey)`.
/// `.system` follows the OS; `.light` / `.dark` force a scheme. Applied once at each app root via
/// `.preferredColorScheme`; every `StrandPalette` token is dynamic, so no per-view plumbing.
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    /// The @AppStorage key shared by the app roots and the Settings picker.
    public static let storageKey = "theme.appearance"

    /// Human label for the Settings control.
    ///
    /// `.light` has an EXPLICIT key because "Light" is also a SLEEP STAGE name and a catalogue key is its
    /// English string; sharing one entry made locales translate it as the sleep stage.
    public var label: String {
        switch self {
        case .system: return String(localized: "System", bundle: .module)
        case .light:  return String(localized: "appearance.light", defaultValue: "Light", bundle: .module)
        case .dark:   return String(localized: "Dark", bundle: .module)
        }
    }

    /// SF Symbol for the Settings control.
    public var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon.stars"
        }
    }

    /// The `ColorScheme` to force, or `nil` to follow the system (the `.system` case).
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// Resolves a stored raw value; unknown/missing falls back to `.system`.
    public static func resolve(_ raw: String) -> AppearanceMode {
        AppearanceMode(rawValue: raw) ?? .system
    }
}

/// Day-cycle scene backdrop behind Today (default ON). When OFF, Today falls back to the opaque
/// `surfaceBase`. Read in `TodayView`; toggled from Settings → Appearance.
public enum SceneBackgroundPrefs {
    /// The @AppStorage key shared by TodayView and the Settings toggle. Default `true`.
    public static let enabledKey = "zoop.showDayCycleBackground"
}

/// Card-surface opacity as a PERCENT (0 = see-through, 100 = solid; default 100), read by
/// `FrostedCardSurface`. Card content stays fully readable.
public enum CardAppearancePrefs {
    public static let opacityKey = "zoop.cardOpacityPercent"
    public static let defaultPercent = 100
}

/// "Sky behind cards" (opt-in, default OFF): extends the day-cycle sky behind the whole Today scroll
/// so card transparency reveals it. Read in `LiquidTodayView`.
public enum SkyBehindCardsPrefs {
    public static let enabledKey = "zoop.skyBehindCards"
}

/// Custom background image: a user-picked photo drawn behind every screen, REPLACING the day-cycle sky
/// when enabled (image > sky > plain canvas). The file is device-local and kept OUT of the `.zoopbak`
/// whitelist; the three key strings are byte-identical across platforms.
public enum BackgroundImagePrefs {
    /// Master gate: when true AND an image is present, the image overrides the sky. Default false.
    public static let enabledKey = "zoop.backgroundImageEnabled"
    /// The `BackgroundFillMode` rawValue. Default `"fill"`.
    public static let fillModeKey = "zoop.backgroundFillMode"
    /// Whether a background image file is stored (lets the UI offer Remove and skips a decode). Default false.
    public static let presentKey = "zoop.backgroundImagePresent"
    /// Recent images (MRU, up to 3) as `"<file>,<fillMode>;…"`. Device-local: filenames differ per device,
    /// so only the KEY is shared. Default `""`.
    public static let recentsKey = "zoop.backgroundRecents"
}

/// How a custom background is scaled: fill → aspect-fill/crop, fit → aspect-fit, stretch, tile → repeat.
/// RawValues are byte-identical across platforms.
public enum BackgroundFillMode: String, CaseIterable, Identifiable, Sendable {
    case fill, fit, stretch, tile

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .fill:    return String(localized: "Fill", bundle: .module)
        case .fit:     return String(localized: "Fit", bundle: .module)
        case .stretch: return String(localized: "Stretch", bundle: .module)
        case .tile:    return String(localized: "Tile", bundle: .module)
        }
    }

    /// Tolerant parse; unknown/legacy rawValues fall back to `.fill`.
    public static func resolve(_ raw: String) -> BackgroundFillMode { BackgroundFillMode(rawValue: raw) ?? .fill }
}
