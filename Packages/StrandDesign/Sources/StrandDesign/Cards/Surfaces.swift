import SwiftUI

// MARK: - Non-card surfaces (Zoop 2.0 §7.3)
//
// A whole card is one of the four card types. Everything smaller that still needs a filled shape —
// a well inside a card, a stat cell, a floating pill or tooltip — uses one of these two modifiers,
// so the fill, rim and elevation stay defined in one place (`ZoopPanelSurface`, internal).

public extension View {
    /// A small panel inside a card or sheet: a stat cell, a row group, a readout well. Flat surface
    /// fill at a compact radius; `tint` adds the faint domain wash on macOS (iOS stays flat).
    func zoopInsetSurface(radius: CGFloat = ZoopRadius.tile, tint: Color? = nil) -> some View {
        background(ZoopPanelSurface(tint: tint, cornerRadius: radius, elevated: false))
    }

    /// A floating control: a pill, a tooltip, an overlay button. Same fill as an inset panel, with
    /// the raised elevation on macOS so it reads above the content it floats over.
    func zoopControlSurface(radius: CGFloat = ZoopRadius.button, tint: Color? = nil) -> some View {
        background(ZoopPanelSurface(tint: tint, cornerRadius: radius, elevated: true))
    }
}
