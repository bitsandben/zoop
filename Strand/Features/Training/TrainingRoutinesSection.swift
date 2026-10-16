import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

/// "Routinen" on the Training page: the saved Lift Log routines with their exercise count, the next day
/// they are planned on and what progression suggests for next time. Tap opens the routine; the calendar
/// icon picks its weekdays; "+ Routine" builds one with AI (a form, then one request) or by hand.
struct TrainingRoutinesSection: View {
    let programs: [LiftProgramRow]
    /// Reloads the page after a routine was saved.
    let onChanged: () async -> Void

    @EnvironmentObject private var repo: Repository
    @AppStorage(TrainingPlan.storageKey) private var planRaw = ""

    @State private var info: [String: RoutineInfo] = [:]
    @State private var choosing = false
    @State private var generating = false
    @State private var editing: Target?
    @State private var planning: Target?

    struct RoutineInfo: Equatable {
        var exercises: Int
        var hint: String?
    }

    private struct Target: Identifiable {
        let program: LiftProgramRow?
        var id: String { program?.id ?? "new" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            ZoopSectionHeader("zoop.routines.title", actionTitle: "zoop.routines.add") { choosing = true }
            ContentCard {
                if programs.isEmpty {
                    Text(PlanFormat.t("zoop.routines.empty"))
                        .font(ZoopType.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(programs.enumerated()), id: \.element.id) { index, program in
                    row(program).listCardRow(isFirst: index == 0)
                }
            }
        }
        .task(id: "\(programs.map(\.id))-\(programs.map(\.updatedAt))-\(repo.refreshSeq)") { await loadInfo() }
        .confirmationDialog(PlanFormat.t("zoop.routines.title"), isPresented: $choosing, titleVisibility: .hidden) {
            Button(PlanFormat.t("zoop.routines.menu.ai")) { generating = true }
            Button(PlanFormat.t("zoop.routines.menu.manual")) { editing = Target(program: nil) }
        }
        .sheet(isPresented: $generating) {
            LiftRoutineGenerateSheet { await onChanged() }
        }
        .sheet(item: $editing) { target in
            LiftProgramEditorSheet(program: target.program) { await onChanged() }
        }
        .sheet(item: $planning) { target in
            if let program = target.program { LiftProgramPlanSheet(program: program).environmentObject(repo) }
        }
    }

    private func row(_ program: LiftProgramRow) -> some View {
        HStack(spacing: ZoopSpacing.m) {
            Button { editing = Target(program: program) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(program.name)
                        .font(ZoopType.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(subtitle(program))
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                    if let hint = info[program.id]?.hint {
                        Text(hint)
                            .font(ZoopType.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { planning = Target(program: program) } label: {
                Image(systemName: "calendar")
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PlanFormat.t("zoop.routines.plan.a11y"))
        }
    }

    private func subtitle(_ program: LiftProgramRow) -> String {
        var parts: [String] = []
        if let count = info[program.id]?.exercises {
            parts.append(PlanFormat.t("zoop.planchat.routine.count", "\(count)"))
        }
        parts.append(nextDay(program))
        return parts.joined(separator: " · ")
    }

    /// "Heute", "Mi." or "Nicht eingeplant", from the weekly plan and one-off days of the next week.
    private func nextDay(_ program: LiftProgramRow) -> String {
        let plan = TrainingPlan.decode(planRaw)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: today),
                  plan.programIds(on: date).contains(program.id) else { continue }
            if offset == 0 { return PlanFormat.t("zoop.routines.today") }
            return PlanFormat.t("zoop.routines.next", PlanFormat.weekday(calendar.component(.weekday, from: date)))
        }
        return PlanFormat.t("zoop.routines.unplanned")
    }

    private func loadInfo() async {
        guard let store = await repo.storeHandle() else { return }
        var result: [String: RoutineInfo] = [:]
        for program in programs {
            let items = (try? await store.liftProgramItems(programId: program.id)) ?? []
            let lines = await LiftProgressionAdvisor.lines(for: items, repo: repo)
            let hint = items.compactMap { item in
                lines.first { $0.itemId == item.id }?.advice.map { "\(item.exercise): \(PlanFormat.nextTime($0))" }
            }.first
            result[program.id] = RoutineInfo(exercises: items.count, hint: hint)
        }
        info = result
    }
}
