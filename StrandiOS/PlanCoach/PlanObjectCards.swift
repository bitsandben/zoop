import SwiftUI
import StrandAnalytics
import StrandDesign
import StrandImport

/// The plan as an object in the chat: kind, name, start date and status, then the week as a table.
struct PlanObjectCard: View {
    let draft: TrainingPlanDraft
    let status: PlanChatModel.Status
    var actions: PlanCardActions?

    var body: some View {
        ContentCard {
            PlanObjectHeader(icon: "calendar", kindLabel: kindLabel, title: draft.focus ?? draft.name,
                             detail: PlanFormat.t("zoop.planchat.plan.starts", PlanFormat.day(draft.startDay)),
                             status: status)
            PlanWeekTable(rows: draft.sessions.map {
                .init(weekday: $0.weekday, title: $0.title,
                      detail: [PlanFormat.minutes($0.minutes), $0.time].compactMap { $0 }.joined(separator: " · "))
            })
            if let actions { actions }
        }
    }

    private var kindLabel: String {
        if draft.kind == .targetDate, let target = draft.targetDay {
            return PlanFormat.t("zoop.planchat.plan.kind.target", PlanFormat.day(target))
        }
        return PlanFormat.t("zoop.planchat.plan.kind.open")
    }
}

/// A routine as an object in the chat: name, exercise count, then each exercise with its targets.
struct RoutineObjectCard: View {
    let program: ImportedProgram
    let status: PlanChatModel.Status
    var actions: PlanCardActions?

    var body: some View {
        ContentCard {
            PlanObjectHeader(icon: "dumbbell", kindLabel: PlanFormat.t("zoop.planchat.routine.kind"),
                             title: program.name,
                             detail: PlanFormat.t("zoop.planchat.routine.count", "\(program.lines.count)"),
                             status: status)
            VStack(spacing: 0) {
                ForEach(Array(program.lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline) {
                        Text(line.exercise)
                            .font(ZoopType.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: ZoopSpacing.s)
                        Text(targets(line))
                            .font(ZoopType.caption.monospacedDigit())
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .padding(.vertical, ZoopSpacing.s)
                    .overlay(alignment: .top) {
                        if index > 0 { Rectangle().fill(StrandPalette.hairline).frame(height: 1) }
                    }
                }
            }
            if let actions { actions }
        }
    }

    private func targets(_ line: ImportedProgramLine) -> String {
        switch (line.targetSets, line.targetReps) {
        case let (s?, r?): return "\(s) × \(r)"
        case let (s?, nil): return PlanFormat.t("zoop.planchat.routine.sets", "\(s)")
        default: return ""
        }
    }
}

/// Icon, kind, title, date line and status: the top of every object card.
struct PlanObjectHeader: View {
    let icon: String
    let kindLabel: String
    let title: String
    let detail: String
    let status: PlanChatModel.Status

    var body: some View {
        HStack(alignment: .center, spacing: ZoopSpacing.m) {
            Image(systemName: icon)
                .font(ZoopType.headline)
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: ZoopRadius.button, style: .continuous)
                    .fill(StrandPalette.surfaceInset))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(kindLabel)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(title)
                    .font(ZoopType.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 0)
            Text(PlanFormat.t(status == .draft ? "zoop.planchat.status.draft" : "zoop.planchat.status.active"))
                .font(ZoopType.caption.weight(.semibold))
                .foregroundStyle(status == .draft ? StrandPalette.textSecondary : StrandPalette.textPositive)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Tag | Session" for a week, Monday first.
struct PlanWeekTable: View {
    struct Row: Hashable {
        let weekday: Int
        let title: String
        let detail: String
    }

    let rows: [Row]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: ZoopSpacing.l, verticalSpacing: ZoopSpacing.s) {
            GridRow {
                Text(PlanFormat.t("zoop.planchat.table.day"))
                Text(PlanFormat.t("zoop.planchat.table.session")).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(ZoopType.caption.weight(.semibold))
            .foregroundStyle(StrandPalette.textTertiary)
            Divider().overlay(StrandPalette.hairline).gridCellUnsizedAxes(.horizontal)
            ForEach(rows, id: \.self) { row in
                GridRow(alignment: .firstTextBaseline) {
                    Text(PlanFormat.shortWeekday(row.weekday))
                        .font(ZoopType.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(ZoopType.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(row.detail)
                            .font(ZoopType.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Übernehmen / Anpassen under the card the conversation is about.
struct PlanCardActions: View {
    let working: Bool
    let onAccept: () -> Void
    let onAdjust: () -> Void

    var body: some View {
        HStack(spacing: ZoopSpacing.m) {
            ZoopButton("zoop.planchat.accept", systemImage: "checkmark", kind: .primary, fullWidth: true, action: onAccept)
                .disabled(working)
            ZoopButton("zoop.planchat.adjust", kind: .secondary, fullWidth: true, action: onAdjust)
                .disabled(working)
        }
    }
}
