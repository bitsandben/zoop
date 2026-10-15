import SwiftUI
import StrandDesign

// Design Gallery › Tokens: colour roles, type scale, spacing, radii, surfaces, motion.

struct DesignGalleryFoundations: View {
    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) {
            swatches("Surfaces", note: "Canvas → card → overlay; inset for tracks.", surfaces)
            swatches("Text", note: "Primary for values, secondary for meaning, tertiary for units and dates.", text)
            swatches("Metric colours", note: "Fixed per metric (§7.5). Recovery follows its score band.", metrics)
            swatches("Status and accent", note: "Accent only for primary actions and focus, never for data.", status)
            typeScale
            spacing
            radii
            surfacesDemo
            DesignGalleryMotion()
        }
    }

    private typealias Swatch = (name: String, color: Color)

    private var surfaces: [Swatch] {
        [("surfaceBase", StrandPalette.surfaceBase), ("surfaceRaised", StrandPalette.surfaceRaised),
         ("surfaceOverlay", StrandPalette.surfaceOverlay), ("surfaceInset", StrandPalette.surfaceInset),
         ("hairline", StrandPalette.hairline), ("hairlineStrong", StrandPalette.hairlineStrong)]
    }

    private var text: [Swatch] {
        [("textPrimary", StrandPalette.textPrimary), ("textSecondary", StrandPalette.textSecondary),
         ("textTertiary", StrandPalette.textTertiary)]
    }

    private var metrics: [Swatch] {
        [("Recovery high · recovery100", StrandPalette.recovery100),
         ("Recovery medium · recovery055", StrandPalette.recovery055),
         ("Recovery low · recovery000", StrandPalette.recovery000),
         ("Strain · effortColor", StrandPalette.effortColor),
         ("Sleep · metricPurple", StrandPalette.metricPurple),
         ("Stress · stressHigh", StrandPalette.stressHigh),
         ("Fasting · metricCyan", StrandPalette.metricCyan)]
    }

    private var status: [Swatch] {
        [("accent", StrandPalette.accent), ("statusPositive", StrandPalette.statusPositive),
         ("statusWarning", StrandPalette.statusWarning), ("statusCritical", StrandPalette.statusCritical),
         ("primaryButtonFill", StrandPalette.primaryButtonFill)]
    }

    private func swatches(_ title: String, note: String, _ items: [Swatch]) -> some View {
        GallerySection(title: title, note: note) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: ZoopSpacing.m)],
                      alignment: .leading, spacing: ZoopSpacing.m) {
                ForEach(items, id: \.name) { item in
                    VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
                        RoundedRectangle(cornerRadius: ZoopRadius.button, style: .continuous)
                            .fill(item.color)
                            .overlay(RoundedRectangle(cornerRadius: ZoopRadius.button, style: .continuous)
                                .strokeBorder(StrandPalette.hairline, lineWidth: ZoopMetrics.hairlineWidth))
                            .frame(height: 48)
                        GalleryCaption(item.name)
                    }
                }
            }
        }
    }

    private var typeScale: some View {
        GallerySection(title: "Type scale", note: "ZoopType: the only six sizes. All scale with Dynamic Type.") {
            ContentCard {
                typeRow("62", font: ZoopType.display, token: "display · hero number")
                typeRow("Recovery", font: ZoopType.title, token: "title · nav large title")
                typeRow("54 bpm", font: ZoopType.metric, token: "metric · tile / row value")
                typeRow("What shaped it", font: ZoopType.headline, token: "headline · card / section title")
                typeRow("Your nervous system recovered well overnight.", font: ZoopType.body,
                        token: "body · the meaning sentence")
                typeRow("+8 ms vs. typical · As of 12 Oct", font: ZoopType.caption,
                        token: "caption · units, deltas, data age")
            }
        }
    }

    private func typeRow(_ sample: String, font: Font, token: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: sample).font(font).foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            GalleryCaption(token)
        }
    }

    private var spacing: some View {
        let steps: [(String, CGFloat)] = [("xs", ZoopSpacing.xs), ("s", ZoopSpacing.s), ("m · cardGap", ZoopSpacing.m),
                                          ("l · gutter, cardPadding", ZoopSpacing.l),
                                          ("xl · sectionGap", ZoopSpacing.xl), ("xxl", ZoopSpacing.xxl)]
        return GallerySection(title: "Spacing", note: "ZoopSpacing, 4-pt grid.") {
            ContentCard {
                ForEach(steps, id: \.0) { name, value in
                    HStack(spacing: ZoopSpacing.m) {
                        Rectangle().fill(StrandPalette.textSecondary).frame(width: value, height: ZoopSpacing.s)
                        GalleryCaption("\(name) · \(Int(value)) pt")
                    }
                }
            }
        }
    }

    private var radii: some View {
        let items: [(String, CGFloat)] = [("card 24", ZoopRadius.card), ("tile 18", ZoopRadius.tile),
                                          ("button 14", ZoopRadius.button)]
        return GallerySection(title: "Radii", note: "ZoopRadius, always .continuous.") {
            HStack(spacing: ZoopSpacing.m) {
                ForEach(items, id: \.0) { name, radius in
                    VStack(spacing: ZoopSpacing.xs) {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(StrandPalette.surfaceRaised)
                            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .strokeBorder(StrandPalette.hairlineStrong, lineWidth: ZoopMetrics.hairlineWidth))
                            .frame(height: 72)
                        GalleryCaption(name)
                    }
                }
            }
        }
    }

    private var surfacesDemo: some View {
        GallerySection(title: "Surfaces and elevation",
                       note: "Flat: one card surface on the canvas, inset for tracks. No drop shadows on data.") {
            VStack(spacing: ZoopSpacing.cardGap) {
                ContentCard {
                    GalleryCaption("Card surface (ContentCard / HeroCard / ListCard)")
                    RoundedRectangle(cornerRadius: ZoopRadius.button, style: .continuous)
                        .fill(StrandPalette.surfaceInset)
                        .frame(height: 32)
                        .overlay(GalleryCaption("surfaceInset · track / well"))
                }
                Text.gallery("Tile surface · zoopTileSurface()")
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .zoopTileSurface()
            }
        }
    }
}

/// Motion tokens with a live demo; the demo honours Reduce Motion exactly like product code must.
private struct DesignGalleryMotion: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filled = false

    var body: some View {
        GallerySection(title: "Motion",
                       note: "ZoopMotion.screen / .card / .value, gated by Reduce Motion. No looping on data.") {
            ContentCard {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(StrandPalette.surfaceInset)
                        Capsule().fill(StrandPalette.recovery100)
                            .frame(width: filled ? geo.size.width * 0.78 : geo.size.width * 0.12)
                    }
                }
                .frame(height: ZoopMetrics.indicatorTrackHeight)
                GalleryCaption(reduceMotion ? "Reduce Motion is on: the change is instant."
                                            : "ZoopMotion.value spring, 0.34 s response.")
                Button {
                    withAnimation(ZoopMotion.gated(ZoopMotion.value, reduced: reduceMotion)) { filled.toggle() }
                } label: { Text.gallery("Animate") }
                .buttonStyle(ZoopButtonStyle(.secondary))
            }
        }
    }
}
