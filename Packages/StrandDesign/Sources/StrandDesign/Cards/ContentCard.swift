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
///
/// The title row can also carry a one-line `subtitle` under the title and a `trailing` value (a
/// reading, an average) on the right. Charts use the `chart:footer:` initialiser below, which pins the
/// plot to a fixed height and separates an optional footer with a hairline.
public struct ContentCard<Content: View>: View {
    private let title: LocalizedStringKey?
    private let subtitle: String?
    private let trailing: String?
    private let showsChevron: Bool
    private let content: Content

    public init(
        _ title: LocalizedStringKey? = nil,
        subtitle: String? = nil,
        trailing: String? = nil,
        showsChevron: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.showsChevron = showsChevron
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.m) {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: ZoopSpacing.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                        if let subtitle {
                            Text(subtitle).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    Spacer(minLength: 0)
                    if let trailing {
                        Text(trailing).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                    }
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

/// Body of a chart `ContentCard`: the plot at a fixed height, then an optional footer under a hairline.
public struct ChartCardBody<Chart: View, Footer: View>: View {
    let height: CGFloat
    let chart: Chart
    let footer: Footer

    public var body: some View {
        chart.frame(height: height)
        if !(footer is EmptyView) {
            Divider().overlay(StrandPalette.hairline)
            footer
        }
    }
}

public extension ContentCard {
    /// A titled chart card: title row (subtitle, trailing value, optional `›`), the plot at `height`,
    /// and an optional footer (usually `ChartFooter`) under a hairline.
    init<Chart: View, Footer: View>(
        title: LocalizedStringKey,
        subtitle: String? = nil,
        trailing: String? = nil,
        height: CGFloat = ZoopMetrics.chartHeight,
        showsChevron: Bool = false,
        @ViewBuilder chart: () -> Chart,
        @ViewBuilder footer: () -> Footer
    ) where Content == ChartCardBody<Chart, Footer> {
        self.init(title, subtitle: subtitle, trailing: trailing, showsChevron: showsChevron) {
            ChartCardBody(height: height, chart: chart(), footer: footer())
        }
    }

    /// A titled chart card without a footer.
    init<Chart: View>(
        title: LocalizedStringKey,
        subtitle: String? = nil,
        trailing: String? = nil,
        height: CGFloat = ZoopMetrics.chartHeight,
        showsChevron: Bool = false,
        @ViewBuilder chart: () -> Chart
    ) where Content == ChartCardBody<Chart, EmptyView> {
        self.init(title, subtitle: subtitle, trailing: trailing, showsChevron: showsChevron) {
            ChartCardBody(height: height, chart: chart(), footer: EmptyView())
        }
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
