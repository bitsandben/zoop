import SwiftUI

// MARK: - The four card types (Zoop 2.0 §7.3)
//
// HeroCard, ContentCard, TileGrid/zoopTileSurface, ListCard. They share ONE surface so the card look
// lives in a single place: the existing frosted surface at the 2.0 radius. The surface is a
// `.background` so animations never reach the content subtree (#104).

/// Surface shared by every 2.0 card type.
struct ZoopCardSurface: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content.background { FrostedCardSurface(cornerRadius: radius) }
    }
}

/// Any grouped content: a title row (with an optional `›` when the card navigates) and a body.
public struct ContentCard<Content: View>: View {
    private let title: LocalizedStringKey?
    private let showsChevron: Bool
    private let content: Content

    public init(
        _ title: LocalizedStringKey? = nil,
        showsChevron: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.showsChevron = showsChevron
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.m) {
            if let title {
                HStack {
                    Text(title).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 0)
                    if showsChevron {
                        Image(systemName: "chevron.right")
                            .font(ZoopType.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
            }
            content
        }
        .padding(ZoopSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ZoopCardSurface(radius: ZoopRadius.card))
    }
}

/// Top of a screen: hosts the metric hero and one chart. Same surface as `ContentCard`, no title row,
/// and extra bottom room so the chart does not crowd the card edge.
public struct HeroCard<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.l) { content }
            .padding(.horizontal, ZoopSpacing.cardPadding)
            .padding(.top, ZoopSpacing.cardPadding)
            .padding(.bottom, ZoopSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(ZoopCardSurface(radius: ZoopRadius.card))
    }
}

/// Rows with hairline separators (metric rows, settings, sessions). Separators are drawn by
/// `listCardRow(isFirst:)`, so the card needs no knowledge of its children.
public struct ListCard<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, ZoopSpacing.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(ZoopCardSurface(radius: ZoopRadius.card))
    }
}

public extension View {
    /// Row inside a `ListCard`: vertical padding plus a hairline above unless it is the first row.
    func listCardRow(isFirst: Bool = false) -> some View {
        padding(.vertical, ZoopSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                if !isFirst { Rectangle().fill(StrandPalette.hairline).frame(height: 1) }
            }
    }
}
