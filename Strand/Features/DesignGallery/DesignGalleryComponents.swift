import SwiftUI
import Charts
import StrandDesign

// Design Gallery › Components: the four card types, section headers, buttons and chart styling.

struct DesignGalleryComponents: View {
    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) {
            cards
            headers
            buttons
            DesignGalleryCharts()
        }
    }

    private var cards: some View {
        GallerySection(title: "Cards", note: "Exactly four types (§7.3). All share one surface.") {
            VStack(alignment: .leading, spacing: ZoopSpacing.cardGap) {
                HeroCard {
                    MetricHero(DesignGallerySamples.recovery(78))
                }
                GalleryCaption("HeroCard · top of a screen: MetricHero + one chart")
                ContentCard(.gallery("Sleep tonight"), showsChevron: true) {
                    Text.gallery("Go to bed by 22:40 to cover your sleep need.")
                        .font(ZoopType.body).foregroundStyle(StrandPalette.textSecondary)
                }
                GalleryCaption("ContentCard · title row (+ › when it navigates), body")
                ListCard {
                    ForEach(Array(["Morning check-in", "Journal", "Fasting plan"].enumerated()), id: \.offset) { i, title in
                        HStack {
                            Text(verbatim: title).font(ZoopType.body).foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right").font(ZoopType.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .listCardRow(isFirst: i == 0)
                    }
                }
                GalleryCaption("ListCard · rows with listCardRow(isFirst:) hairlines")
                TileGrid {
                    ForEach(DesignGallerySamples.tiles.prefix(4)) { MetricTile($0) }
                }
                GalleryCaption("TileGrid of MetricTile · 2-up numbers")
            }
        }
    }

    private var headers: some View {
        GallerySection(title: "Section headers", note: "ZoopSectionHeader above a card, never inside it.") {
            ContentCard {
                ZoopSectionHeader(.gallery("What shaped it"))
                Rectangle().fill(StrandPalette.hairline).frame(height: ZoopMetrics.hairlineWidth)
                ZoopSectionHeader(.gallery("Sessions"),
                                  subtitle: .gallery("Last 7 days, newest first."),
                                  actionTitle: .gallery("All")) {}
            }
        }
    }

    private var buttons: some View {
        GallerySection(title: "Buttons", note: "ZoopButton / ZoopButtonStyle. One primary per screen.") {
            ContentCard {
                ZoopButton(.gallery(GalleryCopy.primary), systemImage: "play.fill", kind: .primary) {}
                ZoopButton(.gallery(GalleryCopy.secondary), systemImage: "plus", kind: .secondary) {}
                ZoopButton(.gallery(GalleryCopy.tertiary), kind: .tertiary) {}
                ZoopButton(.gallery(GalleryCopy.destructive), systemImage: "trash", kind: .destructive) {}
                ZoopButton(.gallery(GalleryCopy.disabled), kind: .primary) {}.disabled(true)
                ZoopButton(.gallery(GalleryCopy.fullWidth), kind: .primary, fullWidth: true) {}
            }
        }
    }
}

/// Swift Charts with the ZoopChartStyle helpers: band, mean rule, gap, four y-labels, day axis.
private struct DesignGalleryCharts: View {
    private struct Point: Identifiable {
        let date: Date
        let value: Double
        let segment: Int
        var id: Date { date }
    }

    private var points: [Point] {
        DesignGallerySamples.trend.map { p in
            let gapStart = DesignGallerySamples.trend[12].date
            return Point(date: p.date, value: p.value, segment: p.date < gapStart ? 0 : 1)
        }
    }

    private var week: [Point] { Array(points.suffix(7)) }

    var body: some View {
        GallerySection(title: "Charts", note: "Title (what) · band or rule (compared to what) · takeaway (so what).") {
            VStack(alignment: .leading, spacing: ZoopSpacing.cardGap) {
                ContentCard(.gallery(GalleryCopy.hrvChart)) {
                    trendChart.frame(height: 180)
                    Text.gallery("Above your range on 5 of the last 7 days.")
                        .font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                GalleryCaption("ZoopBandMark 15 % · zoopReferenceRule mean · ZoopGapMark · zoopYAxis · zoopDayXAxis(30)")
                ContentCard(.gallery(GalleryCopy.strainChart)) {
                    Chart(week) { p in
                        BarMark(x: .value("Day", p.date, unit: .day), y: .value("Strain", p.value / 5))
                            .foregroundStyle(StrandPalette.effortColor)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .zoopYAxis()
                    .zoopDayXAxis(days: 7)
                    .frame(height: 140)
                    Text.gallery("A steady week with one demanding day.")
                        .font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                GalleryCaption("Bars in the metric colour · weekday letters for 7 days")
            }
        }
    }

    private var trendChart: some View {
        let all = DesignGallerySamples.trend
        let tint = StrandPalette.metricPurple
        return Chart {
            ForEach(points) { p in
                ZoopBandMark(x: .value("Day", p.date), low: 50, high: 58, color: tint)
            }
            RuleMark(y: .value("Typical", 54)).zoopReferenceRule()
            ZoopGapMark(from: .value("Day", all[11].date), to: .value("Day", all[12].date))
            ForEach(points) { p in
                LineMark(x: .value("Day", p.date), y: .value("HRV", p.value), series: .value("Segment", p.segment))
                    .foregroundStyle(tint)
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .zoopYAxis()
        .zoopDayXAxis(days: 30)
        .accessibilityLabel(Text.gallery(GalleryCopy.hrvChartA11y))
    }
}
