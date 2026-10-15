import SwiftUI

/// A two-up grid of metric tiles; the cells own their surface, so the grid is pure layout.
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
    /// The shared tile surface (radius 18), as a modifier so `MetricTile` can compose its own content.
    func zoopTileSurface() -> some View {
        padding(ZoopSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(ZoopCardSurface(radius: ZoopRadius.tile))
    }
}
