import SwiftUI
import StrandDesign
import WhoopStore

/// The value a session row pushes: the natural key of the workout, resolved against the loaded rows
/// where the destination is built.
struct TrainingRoute: Hashable {
    let startTs: Int
    let sport: String
}

// MARK: - Session row
//
// One session in the list. Line one: sport and Effort on the user's scale. Line two: date and time.
// Line three: duration, energy, distance, heart rate. Three short lines instead of one truncated one,
// and no source chip: where a session came from only decides which actions its menu offers.
// The tap pushes the workout detail; in selection mode it toggles the row instead.

struct TrainingSessionRow: View {
    let row: WorkoutRow
    let effortScale: EffortScale
    let format: TrainingFormat
    @ObservedObject var model: TrainingViewModel

    private static let menuWidth: CGFloat = 36

    /// Common sports offered when re-labelling a detected bout; the user can fine-tune via Edit afterwards.
    private static let relabelSports = ["Running", "Walking", "Cycling", "Strength Training",
                                        "Swimming", "Rowing", "Yoga", "HIIT",
                                        "CrossFit", "Hiking", "Tennis"]

    var body: some View {
        let selectable = WorkoutMerge.isMergeable(row)
        Group {
            if model.selectionMode {
                Button {
                    guard selectable else { return }
                    withAnimation(.easeOut(duration: 0.12)) { model.toggleSelection(row) }
                } label: { content(selectable: selectable) }
            } else {
                NavigationLink(value: TrainingRoute(startTs: row.startTs, sport: row.sport)) {
                    content(selectable: selectable)
                }
            }
        }
        .buttonStyle(LiquidPressStyle())
        // The actions menu sits over the row's reserved trailing column, outside the row's button, so it
        // takes its own taps instead of the row's (#318).
        .overlay(alignment: .trailing) {
            if !model.selectionMode { actionsMenu }
        }
        .contextMenu { if !model.selectionMode { menu } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(selectable: selectable))
        .accessibilityHint(model.selectionMode
            ? (selectable ? String(localized: "Double-tap to select") : String(localized: "Imported history can't be merged"))
            : String(localized: "Opens workout detail"))
    }

    // MARK: Content

    private func content(selectable: Bool) -> some View {
        HStack(spacing: ZoopSpacing.m) {
            if model.selectionMode { selectionGlyph(selectable: selectable) }
            Image(systemName: sportSymbol(row.sport))
                .font(ZoopType.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: ZoopSpacing.s) {
                    Text(WorkoutSource.displaySport(row.sport))
                        .font(ZoopType.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(TrainingEffort.cellLabel(strain: row.strain, scale: effortScale))
                        .font(ZoopType.body.monospacedDigit().weight(.semibold))
                        .foregroundStyle(row.strain != nil ? StrandPalette.effortColor : StrandPalette.textTertiary)
                }
                Text("\(format.shortDate(row.startTs)) \u{00B7} \(format.timeRange(start: row.startTs, end: row.endTs))")
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                if let details = details {
                    Text(details)
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            if !model.selectionMode { Color.clear.frame(width: Self.menuWidth) }
        }
        .contentShape(Rectangle())
    }

    /// Duration, energy, distance and heart rate; fields a session lacks are left out, not dashed.
    private var details: String? {
        var parts: [String] = []
        if let seconds = row.durationS, seconds > 0 { parts.append(format.duration(seconds: seconds)) }
        if let kcal = row.energyKcal, kcal > 0 { parts.append(format.energy(kcal)) }
        if let meters = row.distanceM, meters > 0 { parts.append(format.distance(meters: meters)) }
        if let hr = row.avgHr { parts.append(String(localized: "\(hr) bpm")) }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// Filled or hollow check for a row that can be merged; a lock for imported history, which never can.
    @ViewBuilder
    private func selectionGlyph(selectable: Bool) -> some View {
        if selectable {
            Image(systemName: model.isSelected(row) ? "checkmark.circle.fill" : "circle")
                .font(ZoopType.headline)
                .foregroundStyle(model.isSelected(row) ? StrandPalette.effortColor : StrandPalette.textTertiary)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "lock.fill")
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textTertiary.opacity(0.6))
                .frame(width: 20)
                .accessibilityHidden(true)
        }
    }

    private func accessibilityLabel(selectable: Bool) -> String {
        let effort = row.strain != nil
            ? String(localized: "Effort \(TrainingEffort.cellLabel(strain: row.strain, scale: effortScale))")
            : String(localized: "no Effort recorded")
        let summary = [format.shortDate(row.startTs), format.timeRange(start: row.startTs, end: row.endTs), details]
            .compactMap { $0 }.joined(separator: ", ")
        let base = "\(WorkoutSource.displaySport(row.sport)), \(summary), \(effort)"
        guard model.selectionMode else { return base }
        if !selectable { return String(localized: "\(base). Imported, can't be merged.") }
        return model.isSelected(row) ? String(localized: "\(base). Selected.") : String(localized: "\(base). Not selected.")
    }

    // MARK: Actions

    private var actionsMenu: some View {
        Menu { menu } label: {
            Image(systemName: "ellipsis")
                .font(ZoopType.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: Self.menuWidth, height: 44)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// A grandfathered DETECTED bout can be re-labelled as a real session or dismissed. A MANUAL session
    /// can be edited or deleted. Imported rows are read-only history, so they only offer a copy.
    @ViewBuilder
    private var menu: some View {
        switch WorkoutSource.classify(row.source) {
        case .detected:
            Menu("Re-label as") {
                ForEach(Self.relabelSports, id: \.self) { sport in
                    Button(sport) { model.relabel(row, to: sport) }
                }
            }
            Button("Edit details…") { model.editor = .init(editing: row) }
            Divider()
            Button("Dismiss (not a workout)", role: .destructive) { model.dismiss(row) }
        case .manual:
            Button("Edit…") { model.editor = .init(editing: row) }
            Divider()
            Button("Delete", role: .destructive) { model.delete(row) }
        case .whoop, .apple, .lifting, .activityFile:
            Button("Duplicate as manual…") { model.editor = .init(editing: row.asManualCopy, isCopy: true) }
        }
    }
}

private extension WorkoutRow {
    /// A manual-source copy, so "Duplicate as manual" opens the add form pre-filled without ever mutating
    /// the imported original.
    var asManualCopy: WorkoutRow {
        WorkoutRow(startTs: startTs, endTs: endTs, sport: WorkoutSource.displaySport(sport),
                   source: "manual", durationS: durationS, energyKcal: energyKcal,
                   avgHr: avgHr, maxHr: maxHr, strain: strain, distanceM: distanceM,
                   zonesJSON: zonesJSON, notes: notes, steps: steps)
    }
}
