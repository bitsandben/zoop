import SwiftUI
import StrandAnalytics
import StrandDesign

/// "Plan-Update für diese Woche": the weekly review's proposed changes, one reason each. Proposed
/// changes can be deselected, then accepted or declined; an automatic update offers undo. Renders
/// nothing while there is no update, so it can sit on the Training page and in the Coach sheet alike.
struct PlanUpdateCard: View {
    @EnvironmentObject private var repo: Repository
    @State private var pending = TrainingPlanStore.pending
    @State private var skipped: Set<Int> = []
    @State private var working = false

    var body: some View {
        Group {
            if let pending { card(pending) }
        }
        .onReceive(NotificationCenter.default.publisher(for: TrainingPlanStore.pendingChanged)) { _ in
            pending = TrainingPlanStore.pending
            skipped = []
        }
    }

    private func card(_ update: TrainingPlanStore.PendingUpdate) -> some View {
        // Titles only: a change carries its own before / after values.
        let sessions = TrainingPlanStore.plan.sessions ?? []
        let isNextWeek = update.revision.weekKey > PlanReviewRunner.weekKey(for: Date())
        return ContentCard(LocalizedStringKey(isNextWeek ? "zoop.plan.update.titleNext" : "zoop.plan.update.title")) {
            ForEach(Array(update.revision.items.enumerated()), id: \.offset) { index, item in
                row(index: index, text: PlanFormat.sentence(item, sessions: sessions), selectable: !update.applied)
            }
            if update.applied {
                Text(PlanFormat.t("zoop.plan.update.appliedNote"))
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                HStack(spacing: ZoopSpacing.m) {
                    ZoopButton("zoop.plan.update.undo", systemImage: "arrow.uturn.backward", kind: .secondary,
                               fullWidth: true) { Task { await undo() } }
                    ZoopButton("zoop.plan.update.ok", kind: .tertiary, fullWidth: true) { TrainingPlanStore.pending = nil }
                }
                .disabled(working)
            } else {
                HStack(spacing: ZoopSpacing.m) {
                    ZoopButton("zoop.planchat.accept", systemImage: "checkmark", kind: .primary, fullWidth: true) {
                        Task { await accept(update) }
                    }
                    .disabled(working || skipped.count == update.revision.items.count)
                    ZoopButton("zoop.plan.update.decline", kind: .secondary, fullWidth: true) {
                        TrainingPlanStore.pending = nil
                    }
                }
                .disabled(working)
            }
        }
    }

    private func row(index: Int, text: String, selectable: Bool) -> some View {
        let on = !skipped.contains(index)
        return Button {
            if on { skipped.insert(index) } else { skipped.remove(index) }
        } label: {
            HStack(alignment: .top, spacing: ZoopSpacing.s) {
                Image(systemName: selectable ? (on ? "checkmark.circle.fill" : "circle") : "arrow.triangle.2.circlepath")
                    .font(ZoopType.body)
                    .foregroundStyle(on ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                Text(text)
                    .font(ZoopType.body)
                    .foregroundStyle(on ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .accessibilityAddTraits(selectable && on ? .isSelected : [])
    }

    private func accept(_ update: TrainingPlanStore.PendingUpdate) async {
        working = true
        defer { working = false }
        let chosen = update.revision.items.enumerated().filter { !skipped.contains($0.offset) }.map(\.element)
        await TrainingPlanStore.apply(chosen, label: PlanFormat.t("zoop.plan.history.update"), repo: repo)
        TrainingPlanStore.pending = nil
    }

    private func undo() async {
        working = true
        defer { working = false }
        await TrainingPlanStore.undoLast(repo: repo)
        TrainingPlanStore.pending = nil
    }
}
