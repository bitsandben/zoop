import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Zoop theme (Classic / Pastel & Nature)
// The whole-app LOOK, independent of light/dark. `.classic` is flat near-black/lime; `.pastel` is "Pastell & Natur" (sage canvas, white cards, lavender/mint/apricot data worlds, SF Rounded numerals).
// Tokens declare both looks via `Color(classic:pastel:)`; the dynamic provider reads `current` at resolution time (a plain static read, loaded once and updated by `.zoopTheme(_:)`
// at the app root, which re-keys content so every view re-resolves).

public enum ZoopTheme: String, CaseIterable, Identifiable, Sendable {
    case classic
    case pastel

    public var id: String { rawValue }

    /// The @AppStorage key shared by the app root and the Settings picker.
    public static let storageKey = "zoop.theme"

    /// The active theme. Read by every themed token's provider, so it must stay a cheap static read.
    public static var current: ZoopTheme = {
        #if os(watchOS)
        return .classic
        #else
        return resolve(UserDefaults.standard.string(forKey: storageKey) ?? "")
        #endif
    }()

    @inline(__always) public static var isPastel: Bool { current == .pastel }

    public static func resolve(_ raw: String) -> ZoopTheme { ZoopTheme(rawValue: raw) ?? .classic }

    public var label: String {
        switch self {
        case .classic: return String(localized: "theme.classic", defaultValue: "Classic", bundle: .module)
        case .pastel:  return String(localized: "theme.pastel", defaultValue: "Pastel & Nature", bundle: .module)
        }
    }

    /// Preview swatches for the Settings picker: the canvas, then the look's signature colours.
    public var swatches: [Color] {
        switch self {
        case .classic: return [Color(hex: "#0A0A0A"), Color(hex: "#181818"), Color(hex: "#BFEB7B")]
        case .pastel:  return [Color(hex: "#EEF1EC"), Color(hex: "#DCD6F7"), Color(hex: "#CFE8D5"), Color(hex: "#FBE2C4")]
        }
    }
}

public extension View {
    /// Applies the theme: sets `ZoopTheme.current` and keys the content on it so a switch re-resolves every view. Apply at each app root.
    func zoopTheme(_ raw: String) -> some View {
        ZoopTheme.current = ZoopTheme.resolve(raw)
        return self.id("zoop.theme.\(ZoopTheme.current.rawValue)")
    }
}

public extension Color {
    /// A token carrying both looks: `classic` and `pastel` (light, dark) hex pairs, all parsed ONCE here (#2393); the provider picks a ready tuple.
    init(classic: (light: String, dark: String), pastel: (light: String, dark: String)) {
        let c = (light: Color.sRGBComponents(hex: classic.light), dark: Color.sRGBComponents(hex: classic.dark))
        let p = (light: Color.sRGBComponents(hex: pastel.light), dark: Color.sRGBComponents(hex: pastel.dark))
        #if os(watchOS)
        self.init(.sRGB, red: c.dark.r, green: c.dark.g, blue: c.dark.b, opacity: c.dark.a)
        #elseif canImport(UIKit)
        self.init(UIColor { trait in
            let pair = ZoopTheme.current == .pastel ? p : c
            let v = trait.userInterfaceStyle == .dark ? pair.dark : pair.light
            return UIColor(red: CGFloat(v.r), green: CGFloat(v.g), blue: CGFloat(v.b), alpha: CGFloat(v.a))
        })
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let pair = ZoopTheme.current == .pastel ? p : c
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let v = isDark ? pair.dark : pair.light
            return NSColor(srgbRed: CGFloat(v.r), green: CGFloat(v.g), blue: CGFloat(v.b), alpha: CGFloat(v.a))
        })
        #else
        self.init(.sRGB, red: c.dark.r, green: c.dark.g, blue: c.dark.b, opacity: c.dark.a)
        #endif
    }

    /// Shorthand for a token whose classic look is `light`/`dark` and pastel look is `pastel`.
    init(light: String, dark: String, pastel: (light: String, dark: String)) {
        self.init(classic: (light, dark), pastel: pastel)
    }
}
