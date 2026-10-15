import SwiftUI

#if canImport(AppKit)
import AppKit
/// The native bitmap image type for the current platform.
public typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#endif

// MARK: - Image bridging

extension Image {
    /// Builds a SwiftUI `Image` from the platform-native bitmap type.
    init(platformImage: PlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: platformImage)
        #elseif canImport(UIKit)
        self.init(uiImage: platformImage)
        #endif
    }
}

// MARK: - Pasteboard

/// Cross-platform clipboard write.
enum PlatformPasteboard {
    static func copy(_ string: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = string
        #endif
    }
}

// MARK: - Device noun

/// The platform's device noun, so copy doesn't hard-code "Mac" on iPhone. Not for strings that are
/// genuinely Mac-only (e.g. "a Mac can't write to a 5/MG").
enum Platform {
    /// "iPhone" on iOS, "Mac" on macOS. e.g. "Everything stays on your \(Platform.deviceNoun)."
    static var deviceNoun: String {
        #if os(iOS)
        return "iPhone"
        #else
        return "Mac"
        #endif
    }

    /// "this iPhone" / "this Mac"; localized (key "this %@") so the demonstrative reads natively.
    static var deviceNounPhrase: String { String(localized: "this \(deviceNoun)") }
}

// MARK: - Opening URLs

/// Cross-platform "open this URL with the system" helper (`mailto:`, `shortcuts://`).
enum PlatformOpen {
    @MainActor static func url(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }
}

// MARK: - Screen idle (keep-awake)

/// Prevents display auto-lock during a watched session (breathing orb, HIIT timer); iOS-only, no-op
/// on macOS. `isIdleTimerDisabled` is one process-wide flag, so holders are tracked by reason: a
/// strap sync finishing must not unlock the screen under a running breathing session.
enum ScreenIdle {
    enum Reason: Hashable {
        /// A watched on-screen session via `keepAwake`.
        case session
        /// A strap history sync, with Settings "Keep screen on while syncing" on (iOS).
        case strapSync
    }

    /// UserDefaults key for "Keep screen on while syncing" (default OFF), shared by SettingsView and the iOS observer.
    static let strapSyncKeepAwakeKey = "syncKeepScreenOn"

    @MainActor private static var holds: Set<Reason> = []

    /// True while any reason holds the screen awake.
    @MainActor static var isHeld: Bool { !holds.isEmpty }

    /// Single-session API: last writer wins among sessions.
    @MainActor static func keepAwake(_ on: Bool) {
        hold(.session, on)
    }

    @MainActor static func hold(_ reason: Reason, _ on: Bool) {
        if on { holds.insert(reason) } else { holds.remove(reason) }
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = !holds.isEmpty
        #endif
    }
}
