import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Sessions
//
// The session list, newest first: a header with the filter menu and Select, the multi-select strip
// (merge, delete) and the rows. Current shows the ten most recent sessions, Archived the rest.

struct TrainingSessionsSection: View {
    @ObservedObject var model: TrainingViewModel
    let effortScale: EffortScale
    let format: TrainingFormat

    private static let sourceOptions: [WorkoutSource] = [.whoop, .apple, .detected, .manual, .lifting, .activityFile]

    var body: some View {
        let rows = model.visibleRows
        VStack(alignment: .leading, spacing: ZoopSpacing.m) {
            header(rows)
            if model.selectionMode { selectionStrip(rows) }
            if rows.isEmpty {
                Text(model.scope == .archived && !model.filter.isActive
                     ? TrainingStrings.nothingArchived : TrainingStrings.noMatches)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                ListCard {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            TrainingSessionRow(row: row, effortScale: effortScale, format: format, model: model)
                                .listCardRow(isFirst: index == 0)
                        }
                    }
                }
            }
        }
    }

    // MARK: Header

    private func header(_ rows: [WorkoutRow]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ZoopSpacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(TrainingStrings.sessionsTitle)
                    .font(ZoopType.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(caption(count: rows.count))
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 0)
            if rows.contains(where: WorkoutMerge.isMergeable) {
                Button(model.selectionMode ? String(localized: "Done") : String(localized: "Select")) {
                    withAnimation(.easeOut(duration: 0.15)) { model.setSelectionMode(!model.selectionMode) }
                }
                .font(ZoopType.body)
                .foregroundStyle(StrandPalette.accent)
                .accessibilityLabel(model.selectionMode
                    ? String(localized: "Finish selecting")
                    : String(localized: "Select sessions to merge or delete"))
            }
            filterMenu
        }
    }

    /// "10 sessions", plus whatever is narrowing the list.
    private func caption(count: Int) -> String {
        let narrowing = [model.scope == .current ? nil : String(localized: "Archived"),
                         model.sportFilter,
                         model.sourceFilter.map(Self.sourceLabel)].compactMap { $0 }
        return ([TrainingStrings.sessionCount(count)] + narrowing).joined(separator: " \u{00B7} ")
    }

    private var filterMenu: some View {
        Menu {
            Picker("Scope", selection: $model.scope) {
                ForEach(TrainingScope.allCases) { Text($0.label).tag($0) }
            }
            Menu(model.sportFilter ?? String(localized: "All sports")) {
                Button(String(localized: "All sports")) { model.sportFilter = nil }
                Divider()
                ForEach(model.availableSports, id: \.self) { sport in
                    Button(sport) { model.sportFilter = sport }
                }
            }
            Menu(model.sourceFilter.map(Self.sourceLabel) ?? String(localized: "All sources")) {
                Button(String(localized: "All sources")) { model.sourceFilter = nil }
                Divider()
                ForEach(Self.sourceOptions, id: \.self) { option in
                    Button(Self.sourceLabel(option)) { model.sourceFilter = option }
                }
            }
            if model.scope != .current || model.filter.isActive {
                Divider()
                Button(String(localized: "Clear filters"), role: .destructive) {
                    model.scope = .current
                    model.sportFilter = nil
                    model.sourceFilter = nil
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(ZoopType.body)
                .foregroundStyle(model.scope != .current || model.filter.isActive
                                 ? StrandPalette.effortColor : StrandPalette.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(String(localized: "Filter workouts"))
    }

    private static func sourceLabel(_ source: WorkoutSource) -> String {
        switch source {
        case .whoop: return String(localized: "Whoop")
        case .apple: return String(localized: "Apple")
        case .detected: return String(localized: "Detected")
        case .manual: return String(localized: "Manual")
        case .lifting: return String(localized: "Lifting")
        case .activityFile: return String(localized: "File")
        }
    }

    // MARK: Selection

    /// Merge needs two or more mergeable rows; Delete needs one.
    private func selectionStrip(_ rows: [WorkoutRow]) -> some View {
        let chosen = rows.filter(model.isSelected)
        let canMerge = WorkoutMerge.canMerge(chosen)
        return HStack(spacing: ZoopSpacing.m) {
            Button { model.beginMerge(chosen) } label: {
                Label(String(localized: "Merge (\(chosen.count))"), systemImage: "arrow.triangle.merge")
            }
            .disabled(!canMerge)
            .foregroundStyle(canMerge ? StrandPalette.effortColor : StrandPalette.textTertiary)

            Button(role: .destructive) { model.deleteSelected(chosen) } label: {
                Label(String(localized: "Delete (\(chosen.count))"), systemImage: "trash")
            }
            .disabled(chosen.isEmpty)
            .foregroundStyle(chosen.isEmpty ? StrandPalette.textTertiary : StrandPalette.metricRose)

            Spacer(minLength: 0)
            Button(String(localized: "Cancel")) {
                withAnimation(.easeOut(duration: 0.15)) { model.setSelectionMode(false) }
            }
            .foregroundStyle(StrandPalette.textSecondary)
        }
        .font(ZoopType.body)
        .padding(ZoopSpacing.m)
        .background(RoundedRectangle(cornerRadius: ZoopRadius.tile, style: .continuous)
            .fill(StrandPalette.surfaceRaised))
    }
}
