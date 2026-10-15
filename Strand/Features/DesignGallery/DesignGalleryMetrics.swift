import SwiftUI
import StrandDesign

// Design Gallery › Metrics: the metric anatomy (§1.1) in every confidence state and every verdict word.

struct DesignGalleryMetrics: View {
    @State private var explainer: MetricReadout?

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) {
            GallerySection(title: "MetricHero · confidence states",
                           note: "Tap a hero for its explainer sheet.") {
                VStack(alignment: .leading, spacing: ZoopSpacing.cardGap) {
                    ForEach(DesignGallerySamples.states, id: \.0) { name, readout in
                        GalleryCaption(name)
                        HeroCard {
                            Button { explainer = readout } label: { MetricHero(readout) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            GallerySection(title: "Verdict vocabulary",
                           note: "Closed sets: vital vs. range, score band, load, data state. MetricRow.") {
                GalleryRows(items: DesignGallerySamples.verdicts) { MetricRow($0) }
            }
            GallerySection(title: "MetricTile", note: "2-up in a TileGrid; the meaning is the VoiceOver hint.") {
                TileGrid {
                    ForEach(DesignGallerySamples.tiles) { MetricTile($0) }
                }
            }
            GallerySection(title: "MetricRangeBar",
                           note: "Solid band = personal range; dashed = population or provisional.") {
                ContentCard {
                    ForEach(DesignGallerySamples.states.prefix(4), id: \.0) { name, readout in
                        MetricRangeBar(readout)
                        GalleryCaption(name)
                    }
                }
            }
            GallerySection(title: "Compact hero", note: "MetricHero(_, compact: true) for rings and narrow cards.") {
                TileGrid {
                    MetricHero(DesignGallerySamples.recoveryCalibrating, compact: true).zoopTileSurface()
                    MetricHero(DesignGallerySamples.spo2Empty, compact: true).zoopTileSurface()
                }
            }
        }
        .sheet(item: $explainer) { readout in
            MetricExplainerSheet(readout, explanation: DesignGallerySamples.explanation)
        }
    }
}

// MARK: - Templates

struct DesignGalleryTemplates: View {
    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) {
            GallerySection(title: "ZoopEmptyState", note: "Instead of a dash: why, plus what to do.") {
                VStack(alignment: .leading, spacing: ZoopSpacing.cardGap) {
                    ZoopEmptyState(systemImage: "moon.zzz", title: .gallery("No sleep recorded"),
                                   message: .gallery("Wear the strap tonight and your sleep appears here in the morning."))
                    ZoopEmptyState(systemImage: "figure.run", title: .gallery("No workouts this week"),
                                   message: .gallery("Log a session or let the strap detect one."),
                                   actionTitle: .gallery("Log workout")) {}
                    ContentCard(.gallery(GalleryCopy.insideCard)) {
                        ZoopEmptyState(systemImage: "chart.xyaxis.line", title: .gallery("No trend yet"),
                                       message: .gallery("Your trend appears after a few nights."),
                                       style: .plain)
                    }
                }
            }
            GallerySection(title: "ZoopCalibratingState", note: "Progress plus what unlocks when (§5.5).") {
                VStack(alignment: .leading, spacing: ZoopSpacing.cardGap) {
                    calibrating(nights: 0)
                    calibrating(nights: 5)
                    calibrating(nights: 14)
                }
            }
            GallerySection(title: "ZoopStaleNote", note: "One quiet line under the value it dates.") {
                ContentCard {
                    ZoopStaleNote(.stale(since: DesignGallerySamples.lastWeek),
                                  message: .gallery("Sync the strap to update."))
                    ZoopStaleNote(.noData(since: DesignGallerySamples.lastWeek))
                    ZoopStaleNote(.noData(since: nil))
                }
            }
            GallerySection(title: "Page templates", note: "Pushed screens. They use the system appearance.") {
                ListCard {
                    link("MetricDetailScreen · solid", isFirst: true) {
                        MetricDetailScreen(DesignGallerySamples.hrvSolid, explanation: DesignGallerySamples.explanation,
                                           takeaway: .gallery("Above your range on 5 of the last 7 days.")) {
                            ZoopSectionHeader(.gallery("Related"))
                            GalleryRows(items: [DesignGallerySamples.rhrProvisional, DesignGallerySamples.respStale]) {
                                MetricRow($0)
                            }
                        }
                    }
                    link("MetricDetailScreen · no data, empty trend") {
                        MetricDetailScreen(DesignGallerySamples.spo2Empty, explanation: DesignGallerySamples.emptyExplanation)
                    }
                    link("MetricDetailScreen · calibrating") {
                        MetricDetailScreen(DesignGallerySamples.recoveryCalibrating) {
                            calibrating(nights: 2)
                        }
                    }
                    link("ZoopSettingsPage") { GallerySettingsDemo() }
                }
            }
        }
    }

    private func calibrating(nights: Int) -> some View {
        ZoopCalibratingState(
            title: .gallery("Learning your baseline"),
            message: .gallery("Wear the strap at night; each night sharpens your personal range."),
            nightsCollected: nights,
            milestones: [
                .init(nights: 4, title: .gallery("First Recovery score")),
                .init(nights: 7, title: .gallery("Provisional personal range")),
                .init(nights: 14, title: .gallery("Fully calibrated")),
            ],
            tint: StrandPalette.recovery100)
    }

    private func link<Destination: View>(_ title: String, isFirst: Bool = false,
                                         @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                Text(verbatim: title).font(ZoopType.body).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Image(systemName: "chevron.right").font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listCardRow(isFirst: isFirst)
    }
}

private struct GallerySettingsDemo: View {
    @State private var clock = true
    @State private var haptics = false

    var body: some View {
        ZoopSettingsPage(.gallery(GalleryCopy.settingsTitle)) {
            ZoopSettingsGroup(.gallery("Display"), footer: .gallery("Applies to every screen.")) {
                ZoopSettingsToggleRow(.gallery(GalleryCopy.clock24), systemImage: "clock", isOn: $clock, isFirst: true)
                ZoopSettingsToggleRow(.gallery("Haptics"), systemImage: "hand.tap", isOn: $haptics,
                                      note: .gallery("A short tap when a value is saved."))
                ZoopSettingsRow(.gallery("Temperature"), systemImage: "thermometer.medium", value: "°C")
            }
            ZoopSettingsGroup(.gallery("About")) {
                ZoopSettingsRow(.gallery(GalleryCopy.version), value: "2.0", showsChevron: false, isFirst: true)
                ZoopSettingsRow(.gallery(GalleryCopy.limitations))
            }
        }
    }
}
