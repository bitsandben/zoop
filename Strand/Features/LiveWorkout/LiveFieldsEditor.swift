import SwiftUI
import StrandDesign

// MARK: - Live workout field editor
//
// Choose the large field and the grid fields for the running sport. Every change is saved at once under
// `zoop.workout.liveFields.<sport>` and handed back, so the screen behind updates live.

struct LiveFieldsEditor: View {
    let sport: String
    let gps: Bool
    @Binding var layout: LiveWorkoutLayout

    @Environment(\.dismiss) private var dismiss

    private var available: [LiveWorkoutField] { LiveWorkoutField.available(gps: gps) }

    var body: some View {
        NavigationStack {
            ZoopSettingsPage(LocalizedStringKey(LiveWorkoutStrings.customize)) {
                primaryGroup
                fieldsGroup
                ZoopSettingsGroup {
                    Button {
                        LiveWorkoutLayout.reset(sport: sport)
                        layout = LiveWorkoutLayout.defaults(sport: sport, gps: gps)
                    } label: {
                        ZoopSettingsRow(LocalizedStringKey(LiveWorkoutStrings.editorReset),
                                        systemImage: "arrow.counterclockwise", showsChevron: false, isFirst: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private var primaryGroup: some View {
        ZoopSettingsGroup(LocalizedStringKey(LiveWorkoutStrings.editorPrimary),
                          footer: LocalizedStringKey(LiveWorkoutStrings.editorPrimaryFooter)) {
            ForEach(Array(available.filter(\.canBePrimary).enumerated()), id: \.element) { index, field in
                Button { update { $0.setPrimary(field) } } label: {
                    ZoopSettingsRow(LocalizedStringKey(field.title), systemImage: field.systemImage, isFirst: index == 0) {
                        if layout.primary == field {
                            Image(systemName: "checkmark").foregroundStyle(StrandPalette.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(layout.primary == field ? .isSelected : [])
            }
        }
    }

    private var fieldsGroup: some View {
        let footer = LiveWorkoutStrings.editorSavedFor(WorkoutSource.displaySport(sport))
            + (gps ? "" : " " + LiveWorkoutStrings.editorGPSOnly)
        return ZoopSettingsGroup(LocalizedStringKey(LiveWorkoutStrings.editorFields), footer: LocalizedStringKey(footer)) {
            ForEach(Array(available.filter { $0 != layout.primary }.enumerated()), id: \.element) { index, field in
                ZoopSettingsToggleRow(LocalizedStringKey(field.title), systemImage: field.systemImage,
                                      isOn: Binding(get: { layout.fields.contains(field) },
                                                    set: { _ in update { $0.toggle(field) } }),
                                      isFirst: index == 0)
            }
        }
    }

    private func update(_ change: (inout LiveWorkoutLayout) -> Void) {
        var next = layout
        change(&next)
        next.save(sport: sport)
        layout = next
        StrandHaptic.selection.play()
    }
}
