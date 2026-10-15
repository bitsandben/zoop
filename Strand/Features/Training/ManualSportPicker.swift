import SwiftUI
import StrandDesign

// MARK: - Sport picker (Add / Edit workout)
//
// A searchable list over `WorkoutCatalog` with each sport's icon and translated name, recent picks first.
// Search matches the translated and the stored name. Free text stays allowed (#519): a query with no
// exact match can be used as typed. The stored value is always the catalogue name, never the translation.

struct ManualSportPicker: View {
    @Binding var sport: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    private var matches: [WorkoutCatalog.Sport] {
        guard !trimmedQuery.isEmpty else { return WorkoutCatalog.all }
        return WorkoutCatalog.all.filter {
            $0.name.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || WorkoutSource.displaySport($0.name)
                    .range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private var recents: [String] { trimmedQuery.isEmpty ? RecentSportsPrefs.recent() : [] }

    /// Offer the typed text when nothing in the catalogue is exactly that sport.
    private var offersFreeText: Bool {
        !trimmedQuery.isEmpty && !WorkoutCatalog.all.contains {
            $0.name.caseInsensitiveCompare(trimmedQuery) == .orderedSame
                || WorkoutSource.displaySport($0.name).caseInsensitiveCompare(trimmedQuery) == .orderedSame
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) {
                if offersFreeText {
                    ListCard {
                        row(name: trimmedQuery, title: ManualWorkoutStrings.useTyped(trimmedQuery), isFirst: true)
                    }
                }
                if !recents.isEmpty {
                    group(ManualWorkoutStrings.recent, names: recents)
                }
                if matches.isEmpty && !offersFreeText {
                    ZoopEmptyState(systemImage: "magnifyingglass", title: LocalizedStringKey("No workouts found"),
                                   message: LocalizedStringKey("Try a different activity name."), style: .plain)
                } else if !matches.isEmpty {
                    group(ManualWorkoutStrings.allSports, names: matches.map(\.name))
                }
            }
            .padding(.horizontal, ZoopSpacing.gutter)
            .padding(.bottom, ZoopSpacing.xxl)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .searchable(text: $query, prompt: Text("Search workouts"))
        .navigationTitle(Text(ManualWorkoutStrings.sport))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func group(_ title: String, names: [String]) -> some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            Text(title)
                .font(ZoopType.headline)
                .foregroundStyle(StrandPalette.textSecondary)
                .padding(.horizontal, ZoopSpacing.xs)
                .accessibilityAddTraits(.isHeader)
            ListCard {
                ForEach(Array(names.enumerated()), id: \.element) { index, name in
                    row(name: name, title: WorkoutSource.displaySport(name), isFirst: index == 0)
                }
            }
        }
    }

    private func row(name: String, title: String, isFirst: Bool) -> some View {
        Button {
            sport = name
            StrandHaptic.selection.play()
            dismiss()
        } label: {
            HStack(spacing: ZoopSpacing.m) {
                WorkoutTypeIcon(workoutType: name, size: 20, weight: .semibold, color: StrandPalette.effortColor)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(ZoopType.body).foregroundStyle(StrandPalette.textPrimary)
                    if WorkoutCatalog.sport(named: name)?.isDistanceSport == true {
                        Text(verbatim: "GPS").font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                Spacer(minLength: ZoopSpacing.s)
                if sport.caseInsensitiveCompare(name) == .orderedSame {
                    Image(systemName: "checkmark").foregroundStyle(StrandPalette.accent).accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .listCardRow(isFirst: isFirst)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(sport.caseInsensitiveCompare(name) == .orderedSame ? .isSelected : [])
    }
}
