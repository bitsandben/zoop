#if os(iOS)
import SwiftUI
import StrandDesign

/// My Dashboard: the user's tiles two-up, each with its range, verdict and a 30-day sparkline. A tile
/// opens its screen (or its explainer when it has none); pressing and holding explains the number.
struct TodayDashboardSection: View {
    let tiles: [TodayDashboardTile]
    let onExplain: (MetricReadout) -> Void
    let onCustomise: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            ZoopSectionHeader(TodayCopy.dashboard, actionTitle: TodayCopy.customise, action: onCustomise)
                .frame(minHeight: 44)
            if tiles.isEmpty {
                ContentCard {
                    Text(TodayCopy.dashboardEmpty)
                        .font(ZoopType.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Button(action: onCustomise) { Text(TodayCopy.customise) }
                        .buttonStyle(ZoopButtonStyle(.secondary))
                }
            } else {
                // Rows, not a lazy grid: both tiles of a row take the taller one's height, so an empty
                // tile next to one with a sparkline does not leave a ragged edge.
                VStack(spacing: ZoopSpacing.cardGap) {
                    ForEach(rows, id: \.first?.id) { row in
                        HStack(alignment: .top, spacing: ZoopSpacing.cardGap) {
                            ForEach(row) { tile in cell(tile).frame(maxWidth: .infinity, maxHeight: .infinity) }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // An odd tile spans the width instead of leaving a hole in the grid.
                if let single { cell(single) }
            }
        }
        .padding(.top, ZoopSpacing.m)
    }

    private var paired: [TodayDashboardTile] { tiles.count % 2 == 0 ? tiles : Array(tiles.dropLast()) }
    private var rows: [[TodayDashboardTile]] {
        stride(from: 0, to: paired.count, by: 2).map { Array(paired[$0..<min($0 + 2, paired.count)]) }
    }
    private var single: TodayDashboardTile? { tiles.count % 2 == 0 ? nil : tiles.last }

    @ViewBuilder
    private func cell(_ tile: TodayDashboardTile) -> some View {
        if let route = tile.kind.route {
            NavigationLink(value: route) { TodayDashboardTileView(tile: tile) }
                .buttonStyle(LiquidPressStyle())
                .contextMenu {
                    Button { onExplain(tile.readout) } label: {
                        Label { Text(TodayCopy.explain) } icon: { Image(systemName: "info.circle") }
                    }
                }
        } else {
            Button { onExplain(tile.readout) } label: { TodayDashboardTileView(tile: tile) }
                .buttonStyle(LiquidPressStyle())
        }
    }
}

/// One tile: `MetricTile` with the sparkline under it on the same surface.
struct TodayDashboardTileView: View {
    let tile: TodayDashboardTile

    var body: some View {
        VStack(spacing: 0) {
            MetricTile(tile.readout)
            if tile.trend.count >= 2 {
                BodySparkline(points: tile.trend, band: tile.readout.typicalRange,
                              muted: tile.isUnavailable || tile.readout.isStale)
                    .frame(height: 28)
                    .padding(.horizontal, ZoopSpacing.l)
                    .padding(.bottom, ZoopSpacing.l)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: ZoopRadius.tile, style: .continuous)
            .fill(StrandPalette.surfaceRaised))
        .contentShape(RoundedRectangle(cornerRadius: ZoopRadius.tile, style: .continuous))
    }
}

/// "Customise": the tiles on the dashboard (drag to reorder, swipe or tap minus to remove) and the
/// ones that can be added. Edits the screen's `TodayDashboardPrefs.storageKey` value through a binding:
/// a second `@AppStorage` on a dotted key is not told about writes, so Today would not reload.
struct TodayDashboardEditor: View {
    @Binding var raw: String
    @Environment(\.dismiss) private var dismiss

    private var kinds: [TodayTileKind] { TodayDashboardPrefs.decode(raw) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Section-scoped ids: a row moving between sections must not keep the other section's controls.
                    ForEach(kinds, id: \.self) { kind in row(kind).id("shown-" + kind.rawValue) }
                        .onDelete { offsets in
                            offsets.map { kinds[$0] }.forEach { save(TodayDashboardPrefs.removing($0, from: kinds)) }
                        }
                        .onMove { save(TodayDashboardPrefs.moving(kinds, from: $0, to: $1)) }
                } header: {
                    Text(TodayCopy.customiseShown)
                } footer: {
                    Text(TodayCopy.customiseShownNote)
                }
                let more = TodayDashboardPrefs.available(excluding: kinds)
                if !more.isEmpty {
                    Section {
                        ForEach(more, id: \.self) { kind in
                            Button { save(TodayDashboardPrefs.adding(kind, to: kinds)) } label: {
                                HStack(spacing: ZoopSpacing.m) {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(StrandPalette.statusPositive)
                                        .accessibilityHidden(true)
                                    row(kind)
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(StrandPalette.surfaceRaised)
                            .id("more-" + kind.rawValue)
                        }
                    } header: {
                        Text(TodayCopy.customiseMore)
                    }
                }
                Section {
                    Button { raw = "" } label: { Text(TodayCopy.customiseReset) }
                        .foregroundStyle(StrandPalette.accent)
                        .listRowBackground(StrandPalette.surfaceRaised)
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(Text(TodayCopy.customiseTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Text(TodayCopy.customiseDone) }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func row(_ kind: TodayTileKind) -> some View {
        HStack(spacing: ZoopSpacing.m) {
            Image(systemName: kind.systemImage)
                .font(ZoopType.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(kind.label)
                .font(ZoopType.body)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .listRowBackground(StrandPalette.surfaceRaised)
    }

    private func save(_ next: [TodayTileKind]) {
        raw = TodayDashboardPrefs.encode(next)
    }
}
#endif
