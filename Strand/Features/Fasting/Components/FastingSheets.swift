#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign

/// Backdate a start, end a fast earlier than "now", or correct an old one. Validation comes from the
/// model (FastingEngine), so the sheet only binds pickers and shows the one reason it can't save.
struct FastingEditSheet: View {
    let model: FastingModel
    @State var draft: FastingDraft
    @Environment(\.dismiss) private var dismiss

    private var isRunning: Binding<Bool> {
        Binding(get: { draft.end == nil },
                set: { draft.end = $0 ? nil : model.now() })
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(selection: $draft.start, in: ...model.now()) { Text(FastingStrings.started) }
                if draft.canRun {
                    Toggle(isOn: isRunning) { Text(FastingStrings.stillRunning) }
                }
                if let end = draft.end {
                    DatePicker(selection: Binding(get: { end }, set: { draft.end = $0 }),
                               in: ...model.now()) { Text(FastingStrings.ended) }
                }
                if let problem = model.problem(with: draft) {
                    Text(problem).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                if let id = draft.rowID {
                    Button(role: .destructive) {
                        Task { await model.delete(rowID: id); dismiss() }
                    } label: { Text("zoop.fasting.edit.delete") }
                }
            }
            .navigationTitle(Text(draft.rowID == nil ? FastingStrings.startEarlierTitle : FastingStrings.editTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("zoop.fasting.edit.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("zoop.fasting.edit.save") {
                        Task { await model.save(draft); dismiss() }
                    }
                    .disabled(model.problem(with: draft) != nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Move an eating window: the first meal ends the earlier fast, the last meal starts the later one.
struct FastingWindowEditSheet: View {
    let model: FastingModel
    @State var draft: FastingWindowDraft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(selection: $draft.opens, in: ...model.now()) { Text(FastingStrings.firstMeal) }
                    DatePicker(selection: $draft.closes, in: ...model.now()) { Text(FastingStrings.lastMeal) }
                } footer: {
                    Text(FastingStrings.windowEditNote)
                }
                if let problem = model.problem(with: draft) {
                    Text(problem).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .navigationTitle(Text(FastingStrings.windowEditTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("zoop.fasting.edit.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("zoop.fasting.edit.save") {
                        Task { await model.save(draft); dismiss() }
                    }
                    .disabled(model.problem(with: draft) != nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// What the timer means and what it can't know.
struct FastingAboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZoopSpacing.l) {
                    ForEach([FastingStrings.footnote, FastingStrings.aboutPhases,
                             FastingStrings.aboutEvidence, FastingStrings.aboutPatterns], id: \.key) { line in
                        Text(line).font(ZoopType.body).foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(ZoopSpacing.gutter)
            }
            .navigationTitle(Text(FastingStrings.aboutTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("zoop.fasting.done") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }
}
#endif
