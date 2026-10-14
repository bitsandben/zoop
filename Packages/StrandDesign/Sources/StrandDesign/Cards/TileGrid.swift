import SwiftUI

/// A two-up grid of metric tiles with the 2.0 gap. The cells own their surface
/// (`zoopTileSurface()`), so the grid is pure layout.
public struct TileGrid<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: ZoopSpacing.cardGap),
                      GridItem(.flexible(), spacing: ZoopSpacing.cardGap)],
            spacing: ZoopSpacing.cardGap
        ) { content }
    }
}

public extension View {
    /// The tile surface (radius 18). Why a modifier and not a view: `MetricTile` is owned by the
    /// metric work package, which composes its own content and only needs the shared surface.
    func zoopTileSurface() -> some View {
        padding(ZoopSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(ZoopCardSurface(radius: ZoopRadius.tile))
    }
}
