import SwiftUI

// MARK: - Hex Color Helper

public extension Color {
    /// Parse "#RRGGBB" or "#AARRGGBB"/"RRGGBBAA" hex into sRGB components in 0...1.
    /// Shared by `Color(hex:)` and the dynamic `Color(light:dark:)` provider.
    static func sRGBComponents(hex: String) -> (r: Double, g: Double, b: Double, a: Double) {
        let raw = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&int)
        switch raw.count {
        case 8: // RRGGBBAA
            return (Double((int >> 24) & 0xFF) / 255.0, Double((int >> 16) & 0xFF) / 255.0,
                    Double((int >> 8) & 0xFF) / 255.0, Double(int & 0xFF) / 255.0)
        default: // RRGGBB (6) and any fallback
            return (Double((int >> 16) & 0xFF) / 255.0, Double((int >> 8) & 0xFF) / 255.0,
                    Double(int & 0xFF) / 255.0, 1.0)
        }
    }

    /// Create a Color from "#RRGGBB" (6) or "#AARRGGBB" / "RRGGBBAA" (8) hex.
    init(hex: String) {
        let c = Color.sRGBComponents(hex: hex)
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }

    /// A colour that resolves to `light` or `dark` (hex strings) per the active appearance.
    /// Only token definitions change per theme, never call sites.
    init(light: String, dark: String) {
        // Parse both hexes once here: the provider runs per resolution (the liquid layer resolves every frame), so parsing inside it
        // was a hot path (#2393). A cache would need a key, lock and eviction for a value fixed at this line; tokens are `static let`.
        // One tuple, not two `let`s: watchOS resolves straight to dark, so a separate light value would be unused there and warn.
        let components = (light: Color.sRGBComponents(hex: light), dark: Color.sRGBComponents(hex: dark))
        #if os(watchOS)
        // watchOS has no dynamic-provider UIColor and the watch app is always dark, so a token resolves straight to its dark hex.
        self.init(.sRGB, red: components.dark.r, green: components.dark.g,
                  blue: components.dark.b, opacity: components.dark.a)
        #elseif canImport(UIKit)
        self.init(UIColor { trait in
            let c = trait.userInterfaceStyle == .dark ? components.dark : components.light
            return UIColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
        })
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? components.dark : components.light
            return NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
        })
        #else
        self.init(.sRGB, red: components.dark.r, green: components.dark.g,
                  blue: components.dark.b, opacity: components.dark.a)
        #endif
    }
}

// MARK: - Strand Palette
//
// Dark navy canvas with per-domain accent worlds (Charge gold, Effort amber, Rest blue, Stress blue-gold-orange); titanium drives neutral chrome.
// Public API is frozen: property names are used across macOS/iOS and only values are themed.

public enum StrandPalette {

    // MARK: Surfaces — deep navy canvas, tinted frosted cards
    // Background is near-black navy, not pure black; cards float just above it.
    public static let surfaceBase    = ZoopVisualStyle.canvas
    public static let surfaceRaised  = ZoopVisualStyle.surface
    public static let surfaceOverlay = ZoopVisualStyle.surfaceTop
    public static let surfaceInset   = ZoopVisualStyle.inset
    public static let hairline       = ZoopVisualStyle.border
    public static let hairlineStrong = ZoopVisualStyle.borderHighlight

    // MARK: Text — deep navy-ink on paper / cool off-white on navy
    public static let textPrimary    = ZoopVisualStyle.primaryText
    public static let textSecondary  = ZoopVisualStyle.secondaryText
    public static let textTertiary   = ZoopVisualStyle.tertiaryText

    // MARK: Text ON a permanently-dark surface (scheme-invariant)
    // Use these, not textPrimary/Secondary/Tertiary, over a fill pinned dark in BOTH themes (e.g. the over-sky ScreenScaffold title):
    // the regular tokens flip to dark ink in Light and vanish (#1013).
    public static let onDarkPrimary   = Color(hex: "#F4F6F8")

    // MARK: Liquid hero card surface (#1160/#1161)
    // Theme-aware (near-black in Dark, frosted white in Light) and honours card transparency. Its text uses the regular flipping tokens;
    // onDark* is for the always-dark sky backdrop. 8-digit hex = RRGGBBAA.
    public static let heroFill   = Color(light: "FFFFFFD9", dark: "0D0E14CC", pastel: ("FFFFFFF2", "202824E6"))
    public static let heroBorder = Color(light: "0000001A", dark: "FFFFFF1C", pastel: ("2F3A3312", "FFFFFF14"))

    // MARK: Primary pill controls
    // Classic keeps the ink-on-canvas inversion (textPrimary / surfaceBase); Pastel & Nature uses soft lavender fill with deep lavender ink.
    public static let primaryButtonFill = Color(classic: (light: "#17181C", dark: "#F5F5F5"),
                                                pastel: (light: "#DCD6F7", dark: "#B9AFF0"))
    public static let primaryButtonText = Color(classic: (light: "#F3F4F6", dark: "#0A0A0A"),
                                                pastel: (light: "#4A3F8F", dark: "#221D45"))

    // MARK: Decorative shadow
    /// A decorative drop-shadow colour at `opacity`. Classic keeps black; Pastel & Nature light uses a faint sage-ink tint at a third of the strength.
    public static func shadow(_ opacity: Double) -> Color {
        guard ZoopTheme.isPastel else { return .black.opacity(opacity) }
        let a = { (v: Double) in String(format: "%02X", Int((min(1, max(0, v)) * 255).rounded())) }
        return Color(light: "#2F3A33" + a(opacity * 0.35), dark: "#000000" + a(opacity))
    }


    // MARK: Accent — chrome anchor (links, selection, focus). User-selectable via `accentChoice`, default mint (#1068).
    // Only chrome is user-themed; the recovery/strain/sleep data worlds follow `chartStyle`.
    /// The user's chrome-accent choice, set from `@AppStorage(AccentColor.storageKey)` via `.noopAccent(...)`. Default mint.
    public static var accentChoice: AccentColor = .mint
    /// The custom accent's hex, used only when `accentChoice == .custom`. Set alongside `accentChoice`.
    public static var customAccentHex: String = AccentColor.defaultCustomHex
    public static var accent: Color { accentChoice.accent }
    public static var accentHover: Color { accentChoice.accentHover }
    public static var accentMuted: Color { accentChoice.accentMuted }
    /// Focus ring color — the same accent, on both schemes.
    public static var focusRing: Color { accentChoice.focusRing }
    /// Opacity for dimmed/disabled sections (shared so screens don't invent their own value).
    public static let disabledOpacity: Double = 0.45
    /// Liquid-scene activity tint shared by heart-rate feedback and transient sync chrome.
    public static let liquidHeart = Color(light: "#B86A2A", dark: "#D9823E", pastel: ("#C2617F", "#F0A9BF"))

    // MARK: - Chart style (data-viz colour mode) — Titanium (brand) or Classic (throwback)
    // Set from `@AppStorage(ChartStyle.storageKey)`. The data-ramp accessors below (stops, hrZones, sleep stages, stress, status, metric, DomainTheme) branch on it;
    // chrome (surfaces, text, accent) is never touched.
    public static var chartStyle: ChartStyle = .titanium
    @inline(__always) static var isClassic: Bool { chartStyle == .classic }

    // MARK: Classic (throwback) data ramps — the recognizable health-app scale. Light/dark tuned.
    // Recovery: red → orange → amber → lime → green.
    static let cRecovery000 = Color(light: "#CB3A2F", dark: "#E5483B")
    static let cRecovery030 = Color(light: "#D87328", dark: "#EE8B3C")
    static let cRecovery055 = Color(light: "#CFA528", dark: "#F2C53D")
    static let cRecovery078 = Color(light: "#74A53A", dark: "#A6D04E")
    static let cRecovery100 = Color(light: "#2E9E4F", dark: "#46B45A")
    static let cRecoveryStops: [Gradient.Stop] = [
        .init(color: cRecovery000, location: 0.00), .init(color: cRecovery030, location: 0.30),
        .init(color: cRecovery055, location: 0.55), .init(color: cRecovery078, location: 0.78),
        .init(color: cRecovery100, location: 1.00),
    ]
    // Strain: the classic light→deep blue cardiovascular ramp.
    static let cStrain000 = Color(light: "#5E92D6", dark: "#7FB2E8")
    static let cStrain033 = Color(light: "#3A74C4", dark: "#4A90E2")
    static let cStrain066 = Color(light: "#284F9C", dark: "#2F6FCB")
    static let cStrain100 = Color(light: "#1C3E80", dark: "#1E4FA0")
    static let cStrainStops: [Gradient.Stop] = [
        .init(color: cStrain000, location: 0.00), .init(color: cStrain033, location: 0.33),
        .init(color: cStrain066, location: 0.66), .init(color: cStrain100, location: 1.00),
    ]
    // Sleep: grey awake, blue light, deep indigo, purple REM.
    static let cSleepAwake = Color(light: "#8C95A3", dark: "#C9CCD6")
    static let cSleepLight = Color(light: "#3A80D6", dark: "#6FA8E8")
    static let cSleepDeep  = Color(light: "#203E73", dark: "#2A4C8F")
    static let cSleepREM   = Color(light: "#6A4FC0", dark: "#8E6FD6")
    // HR zones: grey → green → yellow → orange → red.
    static let cZone1 = Color(light: "#828D9B", dark: "#9AA7B5")
    static let cZone2 = Color(light: "#2E9E4F", dark: "#46B45A")
    static let cZone3 = Color(light: "#CFA528", dark: "#F2C53D")
    static let cZone4 = Color(light: "#D87328", dark: "#EE8B3C")
    static let cZone5 = Color(light: "#CB3A2F", dark: "#E5483B")

    // MARK: Recovery / Charge gradient — the gold "Charge" colour world
    // Warm metal ramp with no green: 0.00 bronze → 0.30 antique gold → 0.55 brand gold → 0.78 soft gold → 1.00 champagne.
    // Three flat bands: red below 34, orange to 66, lime from 67.
    public static let recovery000 = Color(light: "#C23B3B", dark: "#D64545", pastel: ("#C2617F", "#F0A9BF")) // red band
    public static let recovery030 = Color(light: "#C23B3B", dark: "#D64545", pastel: ("#C2617F", "#F0A9BF")) // red band
    public static let recovery055 = Color(light: "#B25C2E", dark: "#C26A38", pastel: ("#C98232", "#F3C99A")) // orange band
    public static let recovery078 = Color(light: "#4C7A12", dark: "#BFEB7B", pastel: ("#4E9A66", "#9FD6AF")) // teal band
    public static let recovery100 = Color(light: "#4C7A12", dark: "#BFEB7B", pastel: ("#4E9A66", "#9FD6AF")) // teal band

    /// Ordered gradient stops for the recovery scale (Titanium gold ramp, or the Classic red→green).
    public static var recoveryStops: [Gradient.Stop] {
        isClassic ? cRecoveryStops : [
            .init(color: recovery000, location: 0.00),
            .init(color: recovery030, location: 0.335),
            .init(color: recovery055, location: 0.336),
            .init(color: recovery055, location: 0.665),
            .init(color: recovery078, location: 0.666),
            .init(color: recovery100, location: 1.00),
        ]
    }

    /// The signature recovery gradient (bronze → champagne, or Classic red→green).
    public static var recoveryGradient: Gradient { Gradient(stops: recoveryStops) }

    // MARK: Strain / Effort ramp — the amber "Effort" colour world
    // Next four stops: the concept's strain blue, deepening toward low load and brightening toward the top.
    public static let strain000 = Color(light: "#1D4E94", dark: "#22559F", pastel: ("#B06F26", "#D9A066"))
    public static let strain033 = Color(light: "#2860B4", dark: "#2D6CC8", pastel: ("#C4823A", "#E6B27E"))
    public static let strain066 = Color(light: "#336CC0", dark: "#3C7AD4", pastel: ("#D4964F", "#F0C392"))
    public static let strain100 = Color(light: "#3E78CC", dark: "#4A86DC", pastel: ("#E0A866", "#F7D3A8"))

    public static var strainStops: [Gradient.Stop] {
        isClassic ? cStrainStops : [
            .init(color: strain000, location: 0.00),
            .init(color: strain033, location: 0.33),
            .init(color: strain066, location: 0.66),
            .init(color: strain100, location: 1.00),
        ]
    }

    /// The strain gradient (output / heat, or the Classic blue ramp).
    public static var strainGradient: Gradient { Gradient(stops: strainStops) }

    // MARK: Sleep stages — the blue "Rest" colour world (Titanium); Classic adds a purple REM
    // Four distinct hues from the concept palette (grey awake, blue-grey light, strain blue deep, lime REM) so a fragmented hypnogram stays readable.
    public static var sleepAwake: Color { isClassic ? cSleepAwake : t_sleepAwake }
    public static var sleepLight: Color { isClassic ? cSleepLight : t_sleepLight }
    public static var sleepDeep:  Color { isClassic ? cSleepDeep  : t_sleepDeep }
    public static var sleepREM:   Color { isClassic ? cSleepREM   : t_sleepREM }

    // MARK: HR zones — Titanium cool→warm (no green), or the Classic grey→green→yellow→orange→red
    public static var zone1: Color { isClassic ? cZone1 : t_zone1 }
    public static var zone2: Color { isClassic ? cZone2 : t_zone2 }
    public static var zone3: Color { isClassic ? cZone3 : t_zone3 }
    public static var zone4: Color { isClassic ? cZone4 : t_zone4 }
    public static var zone5: Color { isClassic ? cZone5 : t_zone5 }

    /// HR zones indexed 1...5; index 0 mirrors zone1 for convenience.
    public static var hrZones: [Color] { [zone1, zone1, zone2, zone3, zone4, zone5] }

    // MARK: Status — Titanium gold/amber/orange, or the Classic green/amber/red.
    public static var statusPositive: Color { isClassic ? Color(light: "#2E9E4F", dark: "#46B45A") : t_statusPositive }
    public static var statusWarning:  Color { isClassic ? Color(light: "#CFA528", dark: "#F2C53D") : t_statusWarning }
    public static var statusCritical: Color { isClassic ? Color(light: "#CB3A2F", dark: "#E5483B") : t_statusCritical }

    /// Verdict words in the status colours, darkened to meet AA (4.5:1) as body text on `surfaceRaised`.
    public static let textPositive = Color(classic: (light: "#2F6B0E", dark: "#BFEB7B"), pastel: (light: "#2F7346", dark: "#9FD6AF"))
    public static let textWarning = Color(classic: (light: "#94531C", dark: "#E8954F"), pastel: (light: "#93561A", dark: "#F3C99A"))

    /// A decorative glyph's colour. The iOS redesign draws icons white and keeps colour for data and
    /// status, so this returns the primary text colour there and `color` elsewhere.
    public static func icon(_ color: Color) -> Color {
        #if os(iOS)
        textPrimary
        #else
        color
        #endif
    }

    // Stress bands: blue-grey calm, lime middle, orange high. `Muted` variants are the darker "typical day" bars.
    public static let stressLow         = Color(light: "#5C8FB0", dark: "#6E9CBC", pastel: ("#7DB592", "#9FD6AF"))
    public static let stressMedium      = Color(light: "#4C7A12", dark: "#BFEB7B", pastel: ("#8C80D6", "#B9AFF0"))
    public static let stressHigh        = Color(light: "#B86A2A", dark: "#D9823E", pastel: ("#D27B97", "#F0A9BF"))

    // MARK: Per-metric accents — HRV / SpO₂ / energy / risk (Classic leans traditional: purple HRV, red risk)
    public static var metricCyan:   Color { isClassic ? Color(light: "#2E92B4", dark: "#3FA9C9") : t_metricCyan }
    public static var metricPurple: Color { isClassic ? Color(light: "#6A4FC0", dark: "#8E6FD6") : t_metricPurple }
    public static var metricAmber:  Color { isClassic ? Color(light: "#CFA528", dark: "#F2C53D") : t_metricAmber }
    public static var metricRose:   Color { isClassic ? Color(light: "#CB3A2F", dark: "#E5483B") : t_metricRose }

    // MARK: - Titanium & Gold domain "colour worlds"
    // Each daily score owns a two-stop accent gradient (deep → bright) plus a glow for gauges, card tints and heroes.

    // Accent/glow follow the chart style (Classic: Charge green, Effort blue, Rest indigo, Stress amber); the gauge ARC samples the data STOPS above regardless.

    /// Charge (recovery) — gold world / Classic green.
    public static var chargeColor: Color  { isClassic ? Color(light: "#2E9E4F", dark: "#46B45A") : t_chargeColor }
    public static var chargeDeep: Color    { isClassic ? Color(light: "#207A3C", dark: "#2E9E4F") : t_chargeDeep }
    public static var chargeBright: Color  { isClassic ? Color(light: "#5FBE6E", dark: "#86D98E") : t_chargeBright }
    public static var chargeGlow: Color    { isClassic ? Color(light: "#2E9E4F", dark: "#46B45A") : t_chargeGlow }
    /// Diagonal accent pair for the Charge card wash + gauge stroke (deep → bright).
    public static var chargeGradient: Gradient { Gradient(colors: [chargeDeep, chargeBright]) }

    /// Effort (strain) — amber world / Classic blue.
    public static var effortColor: Color   { isClassic ? Color(light: "#3A74C4", dark: "#4A90E2") : t_effortColor }
    public static var effortDeep: Color    { isClassic ? Color(light: "#284F9C", dark: "#2F6FCB") : t_effortDeep }
    public static var effortBright: Color  { isClassic ? Color(light: "#5E92D6", dark: "#7FB2E8") : t_effortBright }
    public static var effortGlow: Color    { isClassic ? Color(light: "#3A74C4", dark: "#4A90E2") : t_effortGlow }
    public static var effortGradient: Gradient { Gradient(colors: [effortDeep, effortBright]) }

    /// Rest (sleep) — blue world / Classic indigo.
    public static var restColor: Color     { isClassic ? Color(light: "#3A80D6", dark: "#6FA8E8") : t_restColor }
    public static var restDeep: Color      { isClassic ? Color(light: "#203E73", dark: "#2A4C8F") : t_restDeep }
    public static var restBright: Color    { isClassic ? Color(light: "#6A4FC0", dark: "#8E6FD6") : t_restBright }
    public static var restGlow: Color      { isClassic ? Color(light: "#3A80D6", dark: "#6FA8E8") : t_restGlow }
    /// The Rest family's most legible LINE colour, for strokes over a busy or translucent surface (e.g. body-clock dial arcs).
    /// No new value: it selects the bright blue in each palette (#6FA8E8 in dark). The families are not parallel (classic `restBright` is purple,
    /// modern `restColor` is muted steel), so naming either token directly is wrong in one palette.
    public static var restLine: Color { isClassic || ZoopTheme.isPastel ? restColor : restBright }

    public static var restGradient: Gradient { Gradient(colors: [restDeep, restBright]) }

    /// Stress — blue→gold→orange world / Classic green→amber→red.
    public static var stressColor: Color   { isClassic ? Color(light: "#CFA528", dark: "#F2C53D") : t_stressColor }
    public static var stressDeep: Color    { isClassic ? Color(light: "#2E9E4F", dark: "#46B45A") : t_stressDeep }
    public static var stressBright: Color  { isClassic ? Color(light: "#CB3A2F", dark: "#E5483B") : t_stressBright }
    public static var stressGlow: Color    { isClassic ? Color(light: "#CFA528", dark: "#F2C53D") : t_stressGlow }
    /// 3-stop gauge ramp: calm → balanced → high.
    public static var stressGradient: Gradient { Gradient(colors: [stressDeep, stressColor, stressBright]) }

    // MARK: Scenic background (NEW) — detail-screen hero gradient + starfield.
    /// Radial canvas: lit center → deep edge. Used by `ScenicHeroBackground` (warm-lit on light).
    public static let scenicCenter     = Color(light: "#FBF6EA", dark: "#1C2128", pastel: ("#F6F8F4", "#1E2622"))
    public static let scenicEdge       = Color(light: "#EDE6D6", dark: "#121518", pastel: ("#EEF1EC", "#161C19"))
    /// Star tint for the scenic starfield (very faint on light; the hero suppresses stars there).
    public static let scenicStar       = Color(light: "#D8CDB6", dark: "#C8CFD8", pastel: ("#DCE2DA", "#C8D2CB"))

    // MARK: - Titanium & Gold core tokens
    // Brand gold ramp (buttons, ring fills, FAB) and neutral titanium ramp (tiles, avatars, icon plates); same names and hexes on Android.

    /// Brand gold — primary accent. Fills stay bright (dark text legible in both schemes); a hair deeper on light.
    public static let gold          = Color(light: "#3A78C8", dark: "#60A0E0", pastel: ("#5E52B0", "#B9AFF0")) // repointed to WHOOP blue (gold killed 2026-06-22)
    /// Bright blue — accent highlight / hover.
    public static let goldLight     = Color(light: "#6FA8E0", dark: "#9FC8F0", pastel: ("#8C80D6", "#D3CCF7"))
    /// Deep blue — accent low stop.
    public static let goldDeep      = Color(light: "#2A5C9E", dark: "#3A78C8", pastel: ("#4A3F8F", "#9E92E6"))
    /// Near-black brown — text / icons placed ON gold surfaces (scheme-invariant; gold fills stay gold).
    // Text and icons on accent fills: dark on the bright lime of dark mode, white on light mode's deep green.
    public static let goldDeepText  = Color(light: "#FFFFFF", dark: "#0A0A0A", pastel: ("#FFFFFF", "#1B2420"))
    /// The bright core dot at a gauge arc tip / sparkline head. White on dark; flips to deep ink on light, where white would vanish into the card.
    public static let tipCore       = Color(light: "#241B06", dark: "#FFFFFF", pastel: ("#FFFFFF", "#1B2420"))
    /// High-vis signal yellow — sparing emphasis (badges / alerts); deepened on light to stay visible.
    public static let signalYellow  = Color(light: "#E8A800", dark: "#FFD63D", pastel: ("#C98232", "#F3C99A"))
    /// 135–155° gold ramp for buttons, ring fills, FAB (light → gold → deep).
    public static let goldGradient  = Gradient(colors: [goldLight, gold, goldDeep])

    /// Brushed-titanium ramp (highlight → body → low → deep) for tiles, avatars and icon plates; mid-grey on light so tiles stay visible on white.
    public static let titaniumTop   = Color(light: "#DDE1E6", dark: "#F1F3F5", pastel: ("#E3E8E1", "#DDE5DD"))
    public static let titaniumMid   = Color(light: "#BBC2C9", dark: "#C9CFD4", pastel: ("#C9D2C7", "#B7C4BA"))
    public static let titaniumLow   = Color(light: "#98A0A8", dark: "#969DA4", pastel: ("#A9B5A8", "#8C9C91"))
    public static let titaniumDeep  = Color(light: "#6B737B", dark: "#6B737B", pastel: ("#7F8F84", "#6A7A70"))


    // MARK: - Themed (default chart style) values, parsed once
    // The non-Classic branch of each data accessor (with its Pastel & Nature pair), so accessors pick a ready token instead of parsing hexes per call.
    static let t_sleepAwake = Color(light: "#8E949E", dark: "#9A9A9A", pastel: ("#D58FA7", "#F0A9BF"))
    static let t_sleepLight = Color(light: "#5C8FB0", dark: "#6E9CBC", pastel: ("#A99FE8", "#D3CCF7"))
    static let t_sleepDeep = Color(light: "#2860B4", dark: "#2D6CC8", pastel: ("#5E52B0", "#8C80E0"))
    static let t_sleepREM = Color(light: "#4C7A12", dark: "#BFEB7B", pastel: ("#5FA9A2", "#9FD6CF"))
    static let t_zone1 = Color(light: "#5C8FB0", dark: "#6E9CBC", pastel: ("#9BB5A3", "#B5CDBD"))
    static let t_zone2 = Color(light: "#4C7A12", dark: "#BFEB7B", pastel: ("#6FB283", "#9FD6AF"))
    static let t_zone3 = Color(light: "#B8962A", dark: "#D9B23E", pastel: ("#D6B05A", "#F1D99A"))
    static let t_zone4 = Color(light: "#B86A2A", dark: "#D9823E", pastel: ("#D98E4A", "#F3C99A"))
    static let t_zone5 = Color(light: "#C23B3B", dark: "#D64545", pastel: ("#C2617F", "#F0A9BF"))
    static let t_statusPositive = Color(light: "#4C7A12", dark: "#BFEB7B", pastel: ("#4E9A66", "#9FD6AF"))
    static let t_statusWarning = Color(light: "#B86A2A", dark: "#D9823E", pastel: ("#C98232", "#F3C99A"))
    static let t_statusCritical = Color(light: "#C23B3B", dark: "#D64545", pastel: ("#C2617F", "#F0A9BF"))
    static let t_metricCyan = Color(light: "#5C8FB0", dark: "#6E9CBC", pastel: ("#5E9FB0", "#A3D3DE"))
    static let t_metricPurple = Color(light: "#2860B4", dark: "#2D6CC8", pastel: ("#6E62C4", "#B9AFF0"))
    static let t_metricAmber = Color(light: "#B25C2E", dark: "#C26A38", pastel: ("#C98232", "#F3C99A"))
    static let t_metricRose = Color(light: "#B86A2A", dark: "#D9823E", pastel: ("#C2617F", "#F0A9BF"))
    static let t_chargeColor = Color(light: "#4C7A12", dark: "#BFEB7B", pastel: ("#4E9A66", "#9FD6AF"))
    static let t_chargeDeep = Color(light: "#3B5F0E", dark: "#8FBF4E", pastel: ("#3F8457", "#86C79A"))
    static let t_chargeBright = Color(light: "#5A8C1A", dark: "#D4F5A4", pastel: ("#6DB383", "#BFE6CA"))
    static let t_chargeGlow = Color(light: "#4C7A12", dark: "#BFEB7B", pastel: ("#4E9A66", "#9FD6AF"))
    static let t_effortColor = Color(light: "#2860B4", dark: "#2D6CC8", pastel: ("#C98232", "#F3C99A"))
    static let t_effortDeep = Color(light: "#1D4E94", dark: "#22559F", pastel: ("#B06F26", "#E3AE72"))
    static let t_effortBright = Color(light: "#3E78CC", dark: "#4A86DC", pastel: ("#E0A866", "#F8DDB8"))
    static let t_effortGlow = Color(light: "#2860B4", dark: "#2D6CC8", pastel: ("#C98232", "#F3C99A"))
    static let t_restColor = Color(light: "#B25C2E", dark: "#C26A38", pastel: ("#6E62C4", "#B9AFF0"))
    static let t_restDeep = Color(light: "#8E4420", dark: "#A9542A", pastel: ("#5E52B0", "#9E92E6"))
    static let t_restBright = Color(light: "#C9783F", dark: "#E08A55", pastel: ("#8C80D6", "#D3CCF7"))
    static let t_restGlow = Color(light: "#B25C2E", dark: "#C26A38", pastel: ("#6E62C4", "#B9AFF0"))
    static let t_stressColor = Color(light: "#C7891A", dark: "#F0A020", pastel: ("#A0739E", "#DDB3D6"))
    static let t_stressDeep = Color(light: "#3A80D6", dark: "#4A90E2", pastel: ("#7DB592", "#9FD6AF"))
    static let t_stressBright = Color(light: "#C84E1E", dark: "#E0662F", pastel: ("#C2617F", "#F0A9BF"))
    static let t_stressGlow = Color(light: "#C7891A", dark: "#F0A020", pastel: ("#A0739E", "#DDB3D6"))

    // MARK: - Sampling helpers

    /// Sample the recovery gradient at a recovery score 0...100.
    public static func recoveryColor(_ score: Double) -> Color {
        sample(stops: recoveryStops, at: score / 100.0)
    }

    /// Sample the strain ("Effort") gradient at a value on Zoop's 0...100 Effort scale.
    public static func strainColor(_ strain: Double) -> Color {
        sample(stops: strainStops, at: strain / 100.0)
    }

    /// Effort tint sampled by a 0...1 fraction (e.g. value/scaleMax), spreading the full ember→amber ramp.
    /// `strainColor(_:)` stays for callers holding a 0...100 value.
    public static func effortTint(fraction: Double) -> Color {
        sample(stops: strainStops, at: min(max(fraction, 0), 1))
    }

    /// The state word for a recovery score: DEPLETED · LOW · MODERATE · PRIMED · PEAK.
    public static func recoveryState(_ score: Double) -> String {
        switch score {
        case ..<25:  return String(localized: "DEPLETED", bundle: .module)
        case ..<50:  return String(localized: "LOW", bundle: .module)
        case ..<70:  return String(localized: "MODERATE", bundle: .module)
        case ..<88:  return String(localized: "PRIMED", bundle: .module)
        default:     return String(localized: "PEAK", bundle: .module)
        }
    }

    /// HR-zone color for a 0...5 zone index (clamped).
    public static func hrZoneColor(_ zone: Int) -> Color {
        let z = max(1, min(5, zone))
        return hrZones[z]
    }

    /// Color for a sleep stage by canonical name (awake/light/deep/rem).
    public static func sleepStageColor(_ stage: SleepStage) -> Color {
        switch stage {
        case .awake: return sleepAwake
        case .light: return sleepLight
        case .deep:  return sleepDeep
        case .rem:   return sleepREM
        }
    }

    // Brand sleep ramps for the stepped hypnogram styles: Ribbon = Oura's (cream awake + blues), Filled = Garmin's (blue light/deep + magenta REM).
    // Opt-in only (Sleep-tab stepped chart); every other Hypnogram caller keeps `sleepStageColor`.
    // Light variants exist because both ramps are dark-tuned: on the near-white light card Oura's awake #EAE3D3 is 1.28:1 and three bands fall under 3:1.
    // Clamping each band alone collapses adjacent stages (Oura rem/light land 1.00:1 apart), so ONE uniform HLS-lightness scale per ramp is applied,
    // pinned so the ramp's lightest band reaches 3:1 on white (Oura ×0.575, Garmin ×0.912). Hue, saturation and stage ordering survive (`BrandSleepRampTests`).
    static let oSleepAwake = Color(light: BrandSleepRamp.ouraAwake.light, dark: BrandSleepRamp.ouraAwake.dark)
    static let oSleepREM   = Color(light: BrandSleepRamp.ouraREM.light,   dark: BrandSleepRamp.ouraREM.dark)
    static let oSleepLight = Color(light: BrandSleepRamp.ouraLight.light, dark: BrandSleepRamp.ouraLight.dark)
    static let oSleepDeep  = Color(light: BrandSleepRamp.ouraDeep.light,  dark: BrandSleepRamp.ouraDeep.dark)
    static let gSleepAwake = Color(light: BrandSleepRamp.garminAwake.light, dark: BrandSleepRamp.garminAwake.dark)
    static let gSleepREM   = Color(light: BrandSleepRamp.garminREM.light,   dark: BrandSleepRamp.garminREM.dark)
    static let gSleepLight = Color(light: BrandSleepRamp.garminLight.light, dark: BrandSleepRamp.garminLight.dark)
    static let gSleepDeep  = Color(light: BrandSleepRamp.garminDeep.light,  dark: BrandSleepRamp.garminDeep.dark)

    /// The brand ramps as hex pairs so tests can assert them (a dynamic `Color` cannot be read back). `.dark` is the shipped ramp.
    enum BrandSleepRamp {
        static let ouraAwake   = (light: "#AD9153", dark: "#EAE3D3")
        static let ouraREM     = (light: "#1A8AC2", dark: "#90D0F0")
        static let ouraLight   = (light: "#176B8E", dark: "#40B0E0")
        static let ouraDeep    = (light: "#12374A", dark: "#206080")
        static let garminAwake = (light: "#EF52E3", dark: "#F26FE8")
        static let garminREM   = (light: "#D91EC7", dark: "#E22DD0")
        static let garminLight = (light: "#3099F0", dark: "#4AA6F2")
        static let garminDeep  = (light: "#2168C5", dark: "#2472D8")

        /// Oura's ramp in stage order (awake → rem → light → deep). Tests assert each ramp keeps its OWN luminance order.
        static let oura   = [ouraAwake, ouraREM, ouraLight, ouraDeep]
        /// Garmin's ramp in stage order.
        static let garmin = [garminAwake, garminREM, garminLight, garminDeep]
    }

    /// A sleep-stage colour in a chosen ramp: Zoop's own tokens, Oura's (Ribbon), or Garmin's (Garmin Fill).
    public static func sleepStageColor(_ stage: SleepStage, palette: SleepStagePalette) -> Color {
        switch palette {
        case .noop: return sleepStageColor(stage)
        case .oura:
            switch stage {
            case .awake: return oSleepAwake
            case .light: return oSleepLight
            case .deep:  return oSleepDeep
            case .rem:   return oSleepREM
            }
        case .garmin:
            switch stage {
            case .awake: return gSleepAwake
            case .light: return gSleepLight
            case .deep:  return gSleepDeep
            case .rem:   return gSleepREM
            }
        }
    }

    // MARK: - Linear gradient stop interpolation

    /// Interpolate a set of gradient stops at a normalized position 0...1.
    /// Clamps out-of-range positions to the end stops.
    public static func sample(stops: [Gradient.Stop], at position: Double) -> Color {
        guard let first = stops.first else { return .clear }
        guard stops.count > 1 else { return first.color }
        let t = min(max(position, 0.0), 1.0)

        var lower = stops[0]
        var upper = stops[stops.count - 1]
        for i in 0..<(stops.count - 1) {
            let a = stops[i]
            let b = stops[i + 1]
            if t >= a.location && t <= b.location {
                lower = a
                upper = b
                break
            }
        }
        let span = upper.location - lower.location
        let localT = span > 0 ? (t - lower.location) / span : 0
        return interpolate(lower.color, upper.color, localT)
    }

    /// Linear-interpolate two colors in sRGB space.
    static func interpolate(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let ca = ColorComponentCache.components(of: a)
        let cb = ColorComponentCache.components(of: b)
        let tt = min(max(t, 0.0), 1.0)
        return Color(
            .sRGB,
            red:   ca.r + (cb.r - ca.r) * tt,
            green: ca.g + (cb.g - ca.g) * tt,
            blue:  ca.b + (cb.b - ca.b) * tt,
            opacity: ca.a + (cb.a - ca.a) * tt
        )
    }
}

// MARK: - Resolved-component memo cache
// PERF: `interpolate(_:_:_:)` is the leaf of all gradient sampling (sparkline points, pips, gauge tips, heat cells) and rebuilt a UIColor/NSColor per call.
// This memoizes resolved sRGB components per Color, keyed on the current appearance too: tokens are dynamic light/dark providers,
// so a bare Color key would go stale after a flip. Bounded so a pathological caller cannot grow it.
enum ColorComponentCache {
    private static var store: [Key: (r: Double, g: Double, b: Double, a: Double)] = [:]
    private static let lock = NSLock()

    private struct Key: Hashable {
        let color: Color
        let appearance: Int
    }

    /// A small integer identifying the current resolved appearance (light vs dark) at this call site.
    private static var appearanceToken: Int {
        #if os(watchOS)
        // No UITraitCollection on watchOS; the watch app is always dark, so the cache key is constant.
        return 1
        #elseif canImport(UIKit)
        return UITraitCollection.current.userInterfaceStyle == .dark ? 1 : 0
        #elseif canImport(AppKit)
        let match = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua])
        return match == .darkAqua ? 1 : 0
        #else
        return 0
        #endif
    }

    static func components(of color: Color) -> (r: Double, g: Double, b: Double, a: Double) {
        // The theme is part of the key too: a themed token resolves differently per ZoopTheme.
        let key = Key(color: color, appearance: appearanceToken + (ZoopTheme.isPastel ? 2 : 0))
        lock.lock()
        if let hit = store[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let resolved = color.rgbaComponents
        lock.lock()
        // Cap the cache; the real working set is the handful of static palette stops, so this is never hit in practice.
        if store.count > 512 { store.removeAll(keepingCapacity: true) }
        store[key] = resolved
        lock.unlock()
        return resolved
    }
}

// MARK: - Sleep stage enum (shared with Hypnogram)

public enum SleepStage: String, CaseIterable, Sendable {
    case awake
    case light
    case deep
    case rem

    public var label: String {
        switch self {
        case .awake: return String(localized: "Awake", bundle: .module)
        case .light: return String(localized: "Light", bundle: .module)
        case .deep:  return String(localized: "Deep", bundle: .module)
        case .rem:   return "REM"
        }
    }

    /// Vertical band order (top = awake, bottom = deep) for hypnogram layout.
    public var bandRank: Int {
        switch self {
        case .awake: return 0
        case .rem:   return 1
        case .light: return 2
        case .deep:  return 3
        }
    }
}

// MARK: - Color component extraction

extension Color {
    /// Resolve to sRGB RGBA components in 0...1. Works on macOS 13+ via platform color bridge.
    var rgbaComponents: (r: Double, g: Double, b: Double, a: Double) {
        #if canImport(AppKit)
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #elseif canImport(UIKit)
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #else
        return (0, 0, 0, 1)
        #endif
    }
}

#if DEBUG
#Preview("Palette") {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            swatchRow("Surfaces", [
                ("base", StrandPalette.surfaceBase),
                ("raised", StrandPalette.surfaceRaised),
                ("overlay", StrandPalette.surfaceOverlay),
                ("inset", StrandPalette.surfaceInset),
                ("hairline", StrandPalette.hairline),
                ("hairline.strong", StrandPalette.hairlineStrong),
            ])
            swatchRow("Text", [
                ("primary", StrandPalette.textPrimary),
                ("secondary", StrandPalette.textSecondary),
                ("tertiary", StrandPalette.textTertiary),
            ])
            swatchRow("Accent", [
                ("accent", StrandPalette.accent),
                ("hover", StrandPalette.accentHover),
                ("muted", StrandPalette.accentMuted),
            ])
            swatchRow("Gold", [
                ("gold", StrandPalette.gold),
                ("light", StrandPalette.goldLight),
                ("deep", StrandPalette.goldDeep),
                ("deepText", StrandPalette.goldDeepText),
                ("signal", StrandPalette.signalYellow),
            ])
            swatchRow("Titanium", [
                ("top", StrandPalette.titaniumTop),
                ("mid", StrandPalette.titaniumMid),
                ("low", StrandPalette.titaniumLow),
                ("deep", StrandPalette.titaniumDeep),
            ])
            VStack(alignment: .leading, spacing: 8) {
                Text("RECOVERY GRADIENT").font(.caption).foregroundStyle(StrandPalette.textTertiary)
                LinearGradient(gradient: StrandPalette.recoveryGradient, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("STRAIN RAMP").font(.caption).foregroundStyle(StrandPalette.textTertiary)
                LinearGradient(gradient: StrandPalette.strainGradient, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            swatchRow("Sleep stages", [
                ("awake", StrandPalette.sleepAwake),
                ("light", StrandPalette.sleepLight),
                ("deep", StrandPalette.sleepDeep),
                ("REM", StrandPalette.sleepREM),
            ])
            swatchRow("HR zones", [
                ("Z1", StrandPalette.zone1), ("Z2", StrandPalette.zone2),
                ("Z3", StrandPalette.zone3), ("Z4", StrandPalette.zone4),
                ("Z5", StrandPalette.zone5),
            ])
        }
        .padding(24)
    }
    .frame(width: 520, height: 760)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}

@ViewBuilder
private func swatchRow(_ title: String, _ items: [(String, Color)]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(title.uppercased())
            .font(.caption)
            .foregroundStyle(StrandPalette.textTertiary)
        HStack(spacing: 10) {
            ForEach(items, id: \.0) { name, color in
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(color)
                        .frame(width: 64, height: 48)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StrandPalette.hairline, lineWidth: 1))
                    Text(name).font(.system(size: 9)).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }
}
#endif
