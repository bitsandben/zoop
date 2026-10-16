import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

/// The Training page's plan block: the weekly update card, then "Dein Plan" (this week's planned sessions
/// with done / missed state, a link to the month calendar) or the way to build a plan. The calendar keeps
/// the month view; this card only answers "what is on this week".
struct PlanCoachSection: View {
    let workouts: [WorkoutRow]

    @EnvironmentObject private var repo: Repository
    @AppStorage(TrainingPlan.storageKey) private var planRaw = ""
    @AppStorage(TrainingPlanStore.autoAdaptKey) private var autoAdapt = false
    @State private var building = false
    @State private var didAutoOpen = false
    @State private var canUndo = !TrainingPlanStore.history.isEmpty

    var body: some View {
        let plan = TrainingPlan.decode(planRaw)
        VStack(alignment: .leading, spacing: ZoopSpacing.cardGap) {
            PlanUpdateCard()
            if let meta = plan.meta, let sessions = plan.sessions, !sessions.isEmpty {
                activeCard(meta, plan: plan)
            } else if CoachBriefScheduler.coachMasterEnabled {
                ContentCard {
                    Text(PlanFormat.t("zoop.plan.entry.note"))
                        .font(ZoopType.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ZoopButton("zoop.planchat.plan.entry", systemImage: "sparkles", kind: .secondary, fullWidth: true) {
                        building = true
                    }
                }
            }
        }
        .task(id: planRaw) {
            await PlanReviewRunner.runIfDue(repo: repo)
            canUndo = !TrainingPlanStore.history.isEmpty
        }
        .fullScreenCover(isPresented: $building) { PlanChatSheet(kind: .plan) }
        #if DEBUG
        .onAppear {
            guard PlanChatDemo.isEnabled, !didAutoOpen else { return }
            didAutoOpen = true
            PlanChatDemo.seedUpdateIfRequested()
            if PlanChatDemo.openTarget == "plan" { building = true }
        }
        #endif
    }

    private func activeCard(_ meta: TrainingPlan.Meta, plan: TrainingPlan) -> some View {
        let kind = meta.kind == "targetDate" && meta.targetDay != nil
            ? PlanFormat.t("zoop.planchat.plan.kind.target", PlanFormat.day(meta.targetDay ?? ""))
            : PlanFormat.t("zoop.planchat.plan.kind.open")
        let entries = PlanWeekStatus.week(plan: plan, workouts: workouts)
        return VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            ZoopSectionHeader("zoop.plan.week.title", subtitle: LocalizedStringKey("\(meta.focus ?? meta.name) · \(kind)"))
            ContentCard {
                if entries.isEmpty {
                    Text(PlanFormat.t("zoop.plan.week.empty"))
                        .font(ZoopType.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    PlanWeekRow(entry: entry).listCardRow(isFirst: index == 0)
                }
                NavigationLink(value: TrainingCalendarRoute()) {
                    HStack {
                        Text(PlanFormat.t("zoop.plan.week.calendar"))
                            .font(ZoopType.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(ZoopType.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listCardRow(isFirst: entries.isEmpty)
                Toggle(isOn: $autoAdapt) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PlanFormat.t("zoop.plan.autoAdapt"))
                            .font(ZoopType.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(PlanFormat.t(autoAdapt ? "zoop.plan.autoAdapt.on" : "zoop.plan.autoAdapt.off"))
                            .font(ZoopType.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(StrandPalette.accent)
                HStack(spacing: ZoopSpacing.m) {
                    ZoopButton("zoop.plan.rebuild", systemImage: "sparkles", kind: .tertiary) { building = true }
                    Spacer(minLength: 0)
                    if canUndo {
                        ZoopButton("zoop.plan.undoLast", systemImage: "arrow.uturn.backward", kind: .tertiary) {
                            Task {
                                await TrainingPlanStore.undoLast(repo: repo)
                                canUndo = !TrainingPlanStore.history.isEmpty
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One planned session: weekday, title, length, and where it stands.
private struct PlanWeekRow: View {
    let entry: PlanWeekStatus.Entry

    var body: some View {
        HStack(spacing: ZoopSpacing.m) {
            Image(systemName: symbol)
                .font(ZoopType.body)
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.session.title)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("\(PlanFormat.weekday(entry.session.weekday)) · \(PlanFormat.sessionDetail(entry.session))")
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 0)
            Text(PlanFormat.t("zoop.plan.week.state.\(key)"))
                .font(ZoopType.caption)
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }

    private var key: String {
        switch entry.state {
        case .done: return "done"
        case .missed: return "missed"
        case .today: return "today"
        case .upcoming: return "upcoming"
        }
    }

    private var symbol: String {
        switch entry.state {
        case .done: return "checkmark.circle.fill"
        case .missed: return "xmark.circle"
        case .today: return "circle.inset.filled"
        case .upcoming: return "circle.dashed"
        }
    }

    private var tint: Color {
        switch entry.state {
        case .done: return StrandPalette.statusPositive
        case .missed: return StrandPalette.textTertiary
        case .today: return StrandPalette.accent
        case .upcoming: return StrandPalette.textSecondary
        }
    }
}
