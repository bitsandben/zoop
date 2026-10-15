import SwiftUI
import StrandDesign
import StrandImport
import WhoopStore

/// "Generate routine": asks the user's configured AI Coach provider for a strength routine and turns
/// the reply into a Lift Log program draft to review before saving.
///
/// Only the short prompt below leaves the device — no metrics, no history. The request goes through
/// `AICoachEngine.oneShot`, so it uses exactly the provider, model and key the Coach is set up with.
struct LiftRoutineGenerateSheet: View {
    /// Called after the program has been saved, so the hub can reload.
    var onSaved: () async -> Void

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var coach: AICoachEngine
    @Environment(\.dismiss) private var dismiss

    @State private var goal = ""
    @State private var equipment = ""
    @State private var minutes = 45
    @State private var focus = ""
    @State private var draft: ImportedProgram?
    @State private var working = false
    @State private var failure: String?
    @FocusState private var focused: Field?

    private enum Field: Hashable { case goal, equipment, focus }

    var body: some View {
        #if os(iOS)
        // iOS asks for the routine in a short guided conversation instead of a form.
        PlanChatSheet(kind: .routine, onSaved: onSaved)
        #else
        formBody
        #endif
    }

    private var formBody: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZoopMetrics.gap) {
                    if !coach.canSendOneShot {
                        ZoopCard {
                            Text("Set up a provider in Coach settings to generate routines.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if let draft {
                        preview(draft)
                    } else {
                        form
                    }
                    if let failure {
                        Text(failure)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.statusCritical)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(ZoopMetrics.screenPadding)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle("Generate routine")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let draft {
                        Button("Save") { Task { await save(draft) } }
                            .disabled(working)
                    }
                }
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #else
        .frame(width: 520, height: 680)
        #endif
    }

    // MARK: - Form

    private var form: some View {
        VStack(alignment: .leading, spacing: ZoopMetrics.gap) {
            ZoopCard {
                VStack(alignment: .leading, spacing: 14) {
                    field("Goal") {
                        TextField("Build muscle", text: $goal)
                            .focused($focused, equals: .goal)
                    }
                    field("Equipment") {
                        TextField("Full gym", text: $equipment)
                            .focused($focused, equals: .equipment)
                    }
                    field("Focus") {
                        TextField("Upper body", text: $focus)
                            .focused($focused, equals: .focus)
                    }
                    Stepper(value: $minutes, in: 15...120, step: 5) {
                        Text("\(minutes) min")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }
            }
            Button {
                Task { await generate() }
            } label: {
                HStack(spacing: 8) {
                    if working { ProgressView().controlSize(.small) }
                    Label("Generate", systemImage: "sparkles")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.noopPrimary)
            .disabled(working)
            Text("Only these answers are sent to your coach provider.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func field<Content: View>(_ label: LocalizedStringKey,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            content()
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }

    // MARK: - Preview

    private func preview(_ program: ImportedProgram) -> some View {
        VStack(alignment: .leading, spacing: ZoopMetrics.gap) {
            ZoopCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text(program.name)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    if let note = program.note {
                        Text(note)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    ForEach(Array(program.lines.enumerated()), id: \.offset) { _, line in
                        lineRow(line)
                    }
                }
            }
            HStack(spacing: ZoopMetrics.rowSpacing) {
                Button {
                    draft = nil
                } label: {
                    Label("Edit answers", systemImage: "chevron.left")
                }
                .buttonStyle(ZoopButtonStyle(.secondary))
                Button {
                    Task { await generate() }
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(ZoopButtonStyle(.secondary))
                .disabled(working)
            }
            Text("Saved as a program you can edit like any other.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func lineRow(_ line: ImportedProgramLine) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(line.exercise)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 8)
                Text(targetsLabel(line))
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            if let muscle = line.primaryMuscle {
                Text(muscle.displayName)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.effortColor)
            }
        }
        .padding(.vertical, 4)
    }

    private func targetsLabel(_ line: ImportedProgramLine) -> String {
        var parts: [String] = []
        if let sets = line.targetSets, let reps = line.targetReps {
            parts.append("\(sets) × \(reps)")
        } else if let sets = line.targetSets {
            parts.append(String(localized: "\(sets) sets"))
        }
        if let rest = line.restSec { parts.append(String(localized: "\(rest) s rest")) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func generate() async {
        guard !working else { return }
        focused = nil
        working = true
        failure = nil
        defer { working = false }
        let request = LiftRoutineGenerator.Request(
            goal: goal, equipment: equipment, minutes: minutes, focus: focus,
            language: Locale.current.language.languageCode?.identifier ?? "en")
        do {
            let reply = try await coach.oneShot(systemPrompt: LiftRoutineGenerator.systemPrompt,
                                                prompt: LiftRoutineGenerator.userPrompt(for: request))
            draft = try LiftRoutineGenerator.parse(reply)
        } catch is LiftRoutineGenerator.ParseError {
            failure = String(localized: "The coach's reply wasn't a routine. Try again.")
        } catch {
            failure = error.localizedDescription
        }
    }

    private func save(_ program: ImportedProgram) async {
        guard !working else { return }
        working = true
        defer { working = false }
        await LiftProgramStarter.save(program, repo: repo)
        await onSaved()
        dismiss()
    }
}
