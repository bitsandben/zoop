import SwiftUI
import StrandAnalytics
import StrandDesign
import StrandImport

/// "Trainingsplan mit KI erstellen" / "Routine mit KI erstellen": a short guided conversation that ends
/// in a plan or routine card to accept or adjust. One question per turn, quick replies where useful.
struct PlanChatSheet: View {
    let kind: PlanInterview.Kind
    /// Called after a plan or routine has been saved.
    var onSaved: () async -> Void = {}

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var coach: AICoachEngine
    @EnvironmentObject private var profile: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model: PlanChatModel
    @State private var saving = false
    @FocusState private var composerFocused: Bool

    private static let bottomID = "planchat.bottom"

    init(kind: PlanInterview.Kind, onSaved: @escaping () async -> Void = {}) {
        self.kind = kind
        self.onSaved = onSaved
        _model = StateObject(wrappedValue: PlanChatModel(
            kind: kind,
            history: WorkoutHistorySummary.make(sessions: [], now: Date(), isStrength: { _ in false }),
            transport: { _, _ in throw AICoachError.noKey }))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: ZoopSpacing.l) {
                        header
                        ForEach(model.messages) { message in
                            PlanChatRow(message: message) { card(for: message) }
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        if model.busy { PlanThinkingRow() }
                        if let error = model.errorText, !model.busy { errorRow(error) }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(.horizontal, ZoopSpacing.gutter)
                    .padding(.vertical, ZoopSpacing.m)
                    .animation(.snappy, value: model.messages.count)
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .onChange(of: model.messages.count) { _, _ in scrollDown(proxy) }
                .onChange(of: model.busy) { _, _ in scrollDown(proxy) }
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(Text(PlanFormat.t(kind == .plan ? "zoop.planchat.plan.title" : "zoop.planchat.routine.title")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(Text(PlanFormat.t("zoop.planchat.close")))
                }
            }
            .toolbarBackground(StrandPalette.surfaceBase, for: .navigationBar)
        }
        .task { await prepare() }
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            PlanCoachAvatar(size: 44)
            Text(PlanFormat.t("zoop.planchat.privacy"))
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, ZoopSpacing.s)
    }

    @ViewBuilder private func card(for message: PlanChatModel.Message) -> some View {
        let actionable = message.id == model.actionableCardId
        switch message.body {
        case .plan(let draft, let status):
            PlanObjectCard(draft: draft, status: status, actions: actionable ? actions { await accept() } : nil)
        case .routine(let program, let status):
            RoutineObjectCard(program: program, status: status, actions: actionable ? actions { await accept() } : nil)
        case .text:
            EmptyView()
        }
    }

    private func actions(_ onAccept: @escaping () async -> Void) -> PlanCardActions {
        PlanCardActions(working: saving || model.busy,
                        onAccept: { Task { await onAccept() } },
                        onAdjust: {
                            model.beginAdjusting()
                            composerFocused = true
                        })
    }

    @ViewBuilder private var bottomBar: some View {
        VStack(spacing: ZoopSpacing.s) {
            if !isConfigured {
                Text(PlanFormat.t("zoop.planchat.setup"))
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if model.phase == .saved {
                ZoopButton("zoop.planchat.done", kind: .primary, fullWidth: true) { dismiss() }
            } else if model.phase != .drafting {
                if model.asksForWeekdays {
                    PlanWeekdayPicker(selected: $model.selectedWeekdays, onSend: send)
                }
                if !model.chips.isEmpty, !model.busy {
                    PlanQuickReplies(replies: model.chips, onSend: send)
                }
                PlanComposer(placeholder: PlanFormat.t(model.phase == .refining || model.phase == .review
                                                       ? "zoop.planchat.composer.adjust" : "zoop.planchat.composer"),
                             disabled: model.busy || saving, focus: $composerFocused, onSend: send)
            }
        }
        .padding(.horizontal, ZoopSpacing.m)
        .padding(.vertical, ZoopSpacing.s)
        .background(StrandPalette.surfaceBase)
    }

    private func errorRow(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            Text(error)
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ZoopButton("zoop.planchat.retry", systemImage: "arrow.clockwise", kind: .tertiary) {
                Task { await model.retry() }
            }
        }
    }

    // MARK: Actions

    private var isConfigured: Bool {
        #if DEBUG
        if PlanChatDemo.isEnabled { return true }
        #endif
        return coach.canSendOneShot
    }

    private func prepare() async {
        #if DEBUG
        if PlanChatDemo.isEnabled {
            model.transport = PlanChatDemo.transport
        } else {
            model.transport = { [coach] system, messages in try await coach.converse(systemPrompt: system, messages: messages) }
        }
        #else
        model.transport = { [coach] system, messages in try await coach.converse(systemPrompt: system, messages: messages) }
        #endif
        model.start(name: profile.name)
        model.updateHistory(await PlanChatApply.historySummary(repo: repo))
        #if DEBUG
        guard PlanChatDemo.isEnabled else { return }
        for answer in PlanChatDemo.answers(kind).prefix(PlanChatDemo.autoAnswers) {
            try? await Task.sleep(nanoseconds: 700_000_000)
            await model.send(answer)
        }
        if PlanChatDemo.autoAccept, model.phase == .review { await accept() }
        #endif
    }

    private func send(_ text: String) {
        Task { await model.send(text) }
    }

    private func accept() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        if let draft = model.latestPlan, kind == .plan {
            await PlanChatApply.apply(draft, repo: repo)
        } else if let program = model.latestRoutine {
            await PlanChatApply.apply(program, repo: repo)
        }
        model.markSaved()
        await onSaved()
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
    }
}
