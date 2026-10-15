import Foundation
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

// Captures the current screen as PNG bytes for the Display test mode's export bundle.
//
// The PNG is binary, so it is not run through redactPii (that scrubs text, not pixels). It is covered
// by the mandatory review-before-share gate, and only captured for the .display profile (gated by the
// assembler behind TestCentre.active(.display) / includesScreenshot).

enum DisplayScreenshot {

    /// The in-zip name of the captured screenshot.
    static let bundleName = "screenshot.png"

    /// Captures the key window as PNG bytes, or nil if there is no window or the render failed. Main thread.
    @MainActor
    static func capturePNG() -> Data? {
        #if os(iOS)
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let window = scene?.keyWindow ?? scene?.windows.first else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            // afterScreenUpdates=false: snapshot what is on screen without forcing a relayout.
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        return image.pngData()
        #elseif os(macOS)
        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first,
              let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
        #else
        return nil
        #endif
    }
}
