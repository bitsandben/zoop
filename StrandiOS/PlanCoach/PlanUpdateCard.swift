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

/// The Training page's plan block: the update card, the active coach plan (or the way to build one).
struct PlanCoachSection: View {
    @EnvironmentObject private var repo: Repository
    @AppStorage(TrainingPlan.storageKey) private var planRaw = ""
    @AppStorage(TrainingPlanStore.autoAdaptKey) private var autoAdapt = false
    @State private var building = false
    @State private var buildingRoutine = false
    @State private var didAutoOpen = false
    @State private var canUndo = !TrainingPlanStore.history.isEmpty

    var body: some View {
        let plan = TrainingPlan.decode(planRaw)
        VStack(alignment: .leading, spacing: ZoopSpacing.cardGap) {
            PlanUpdateCard()
            if let meta = plan.meta, let sessions = plan.sessions, !sessions.isEmpty {
                activeCard(meta, sessions: sessions)
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
        .fullScreenCover(isPresented: $buildingRoutine) { PlanChatSheet(kind: .routine) }
        #if DEBUG
        .onAppear {
            guard PlanChatDemo.isEnabled, !didAutoOpen else { return }
            didAutoOpen = true
            PlanChatDemo.seedUpdateIfRequested()
            if PlanChatDemo.openTarget == "plan" { building = true }
            if PlanChatDemo.openTarget == "routine" { buildingRoutine = true }
        }
        #endif
    }

    private func activeCard(_ meta: TrainingPlan.Meta, sessions: [PlanSession]) -> some View {
        let kind = meta.kind == "targetDate" && meta.targetDay != nil
            ? PlanFormat.t("zoop.planchat.plan.kind.target", PlanFormat.day(meta.targetDay ?? ""))
            : PlanFormat.t("zoop.planchat.plan.kind.open")
        let ordered = sessions.sorted { ($0.weekday + 5) % 7 < ($1.weekday + 5) % 7 }
        return ContentCard {
            PlanObjectHeader(icon: "calendar", kindLabel: kind, title: meta.focus ?? meta.name,
                             detail: PlanFormat.t("zoop.planchat.plan.starts", PlanFormat.day(meta.startDay)),
                             status: .active)
            PlanWeekTable(rows: ordered.map { .init(weekday: $0.weekday, title: $0.title, detail: PlanFormat.sessionDetail($0)) })
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
