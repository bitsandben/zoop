#if os(iOS)
import SwiftUI
import UIKit
import StrandDesign

// MARK: - Theme accent at the window level
//
// SwiftUI's `.tint` does not reach UIKit-presented chrome (sheets, menus, pickers, alerts, links in
// text), which then fall back to the system blue. Setting the window's tint to the theme accent closes
// that gap; the key ties it to the theme and accent so a switch in Settings applies immediately.

extension View {
    /// Applies `StrandPalette.accent` as the SwiftUI tint and as every window's UIKit tint.
    func zoopWindowTint(key: String) -> some View {
        self
            .tint(StrandPalette.accent)
            .onAppear { ZoopWindowTint.apply() }
            .onChange(of: key) { _, _ in ZoopWindowTint.apply() }
    }
}

@MainActor
enum ZoopWindowTint {
    static func apply() {
        let color = UIColor(StrandPalette.accent)
        for scene in UIApplication.shared.connectedScenes {
            guard let windows = (scene as? UIWindowScene)?.windows else { continue }
            for window in windows { window.tintColor = color }
        }
    }
}
#endif
