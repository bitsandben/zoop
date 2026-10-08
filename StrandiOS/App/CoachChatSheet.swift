import SwiftUI
import MarkdownUI
import StrandDesign

// MARK: - Coach chat sheet (iOS)
//
// The Coach button in the tab bar raises this sheet instead of switching tabs. With a provider connected
// it is a chat: messages scroll above a composer docked to the bottom, a reply in progress shows as a
// bubble of three pulsing dots, and the list follows new messages. Without one it walks through setup:
// pick a provider, paste a key, choose whether the coach may read your numbers. A self-hosted server is
// still set up on the full Coach screen, which this sheet links to.

struct CoachChatSheet: View {
    @EnvironmentObject private var coach: AICoachEngine
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if coach.isConfigured {
                    CoachChat(repo: repo)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    CoachSetup()
                        .transition(.opacity)
                }
            }
            .animation(.snappy, value: coach.isConfigured)
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    .accessibilityLabel("Close")
                }
            }
            .toolbarBackground(StrandPalette.surfaceBase, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(StrandPalette.surfaceBase)
        .presentationCornerRadius(28)
    }
}

// MARK: - Chat

private struct CoachChat: View {
    @EnvironmentObject private var coach: AICoachEngine
    /// Passed in rather than observed: the chat only writes to the journal, and observing the repository
    /// would redraw the whole message list on every live reading it publishes.
    let repo: Repository
    @State private var showClearConfirm = false
    /// Whether the end of the conversation is on screen. A streaming reply is followed only while it is,
    /// so scrolling up to reread an earlier answer is not undone by the next words arriving.
    @State private var atBottom = true
    @State private var follow = StreamFollow()
    @FocusState private var composerFocused: Bool

    private static let bottomID = "coach.bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if coach.messages.isEmpty && !coach.sending {
                        emptyState
                    }
                    // A reply streams into a placeholder that starts empty; the dots stand in for it until
                    // the first words arrive.
                    ForEach(coach.messages.filter { !($0.role == .assistant && $0.text.isEmpty) }) { message in
                        CoachBubble(message: message, onSave: save)
                            .equatable()
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                    removal: .opacity))
                    }
                    if waitingForFirstWords {
                        TypingBubble()
                            .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottomLeading)))
                    }
                    if let error = coach.errorText, !error.isEmpty, !coach.sending {
                        errorRow(error)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                        // Before iOS 18 there is no scroll geometry to read; the end marker coming into and
                        // out of view stands in for it.
                        .onAppear { if #unavailable(iOS 18) { atBottom = true } }
                        .onDisappear { if #unavailable(iOS 18) { atBottom = false } }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .animation(.snappy, value: coach.messages.count)
                .animation(.snappy, value: coach.sending)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .modifier(BottomEdgeTracking(atBottom: $atBottom))
            // A tap anywhere on the conversation puts the keyboard away. Simultaneous, so buttons, links,
            // text selection and the bubbles' long-press menus still get their touches.
            .simultaneousGesture(TapGesture().onEnded { if composerFocused { composerFocused = false } })
            .onChange(of: coach.messages.count) { _, _ in
                // A question just sent always brings the end into view; anything else only when already there.
                if coach.messages.last?.role == .user {
                    atBottom = true
                    scrollDown(proxy)
                } else if atBottom {
                    scrollDown(proxy)
                }
            }
            // Follow a streaming reply as it grows, at most a few times a second and only while the
            // reader is at the end.
            .onChange(of: coach.messages.last?.text.count ?? 0) { _, _ in
                if coach.sending { followStream(proxy) }
            }
            .onChange(of: coach.sending) { _, sending in
                if atBottom { scrollDown(proxy) }
                if !sending && !coach.messages.isEmpty {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
            .onChange(of: composerFocused) { _, focused in if focused && atBottom { scrollDown(proxy) } }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 10) {
                    if !coach.sending {
                        CoachChips(prompts: chipPrompts, onSend: send)
                            .equatable()
                    }
                    CoachComposer(sending: coach.sending, focus: $composerFocused, onSend: send)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .background(StrandPalette.surfaceBase)
            }
        }
        .navigationTitle("Coach")
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text("Coach")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    modelMenu
                }
            }
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
        }
        .confirmationDialog("Clear conversation?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { coach.clearConversation() }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            // The same opening sequence as the Coach screen: restore the saved conversation, surface a
            // morning brief that arrived meanwhile, then the first-open brief, each only into an empty one.
            await coach.loadPersistedMessagesIfNeeded()
            coach.retireStaleConversationIfNeeded()
            if coach.messages.isEmpty, let stored = CoachBriefScheduler.consumeStoredBrief() {
                coach.surfaceScheduledBrief(stored)
            }
            CoachBriefScheduler.activateIfEnabled { await coach.generateBrief() }
            await coach.startBriefIfNeeded()
        }
        .task(id: coach.pendingPrompt) {
            guard let prompt = coach.pendingPrompt, !prompt.isEmpty else { return }
            coach.pendingPrompt = nil
            await coach.send(prompt)
        }
    }

    private var waitingForFirstWords: Bool {
        guard coach.sending, let last = coach.messages.last else { return false }
        return last.role == .user || last.text.isEmpty
    }

    private var chipPrompts: [String] {
        (coach.messages.last?.role == .assistant) ? AICoachEngine.followUpSuggestions : coach.suggestions
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
    }

    /// Trailing throttle for a streaming reply: the first chunk in a window books one scroll ~150 ms later,
    /// later chunks in the window ride along, so the list moves in short even glides instead of once per
    /// token. The bookkeeping lives in a reference so it never redraws the list itself.
    private func followStream(_ proxy: ScrollViewProxy) {
        guard atBottom, !follow.pending else { return }
        follow.pending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            follow.pending = false
            guard atBottom else { return }
            withAnimation(.linear(duration: 0.12)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 72, height: 72)
                .background(SquircleShape().fill(StrandPalette.surfaceRaised))
            Text("Ask about your numbers")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
            Text(coach.dataConsent
                 ? "Coach reads your recovery, sleep, strain and workouts to answer."
                 : "Coach can't see your data yet. Turn it on in Coach settings for answers about your own days.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 60)
        .padding(.horizontal, 24)
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !coach.sending else { return }
        Task { await coach.send(trimmed) }
    }

    private func save(_ text: String) {
        let day = Repository.localDayKey(Date())
        Task { await repo.saveJournalAnswer(day: day, question: "Coach advice", answeredYes: true, notes: text) }
    }

    // MARK: Header menus

    private var modelMenu: some View {
        Menu {
            Picker("Model", selection: $coach.model) {
                ForEach(coach.availableModels.isEmpty ? coach.provider.modelOptions : coach.availableModels,
                        id: \.self) { Text($0).tag($0) }
            }
            Button {
                Task { await coach.refreshModels() }
            } label: { Label("Refresh models", systemImage: "arrow.clockwise") }
        } label: {
            HStack(spacing: 3) {
                Text(shortModel)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    /// "meta-llama/llama-3.3-70b-instruct:free" reads as "llama-3.3-70b-instruct".
    private var shortModel: String {
        var m = coach.model
        if let slash = m.lastIndex(of: "/") { m = String(m[m.index(after: slash)...]) }
        if m.hasSuffix(":free") { m.removeLast(5) }
        return m.isEmpty ? coach.provider.displayName : m
    }

    private var moreMenu: some View {
        Menu {
            NavigationLink {
                CoachSettingsPage()
            } label: { Label("Coach settings", systemImage: "slider.horizontal.3") }
            Button(role: .destructive) { showClearConfirm = true } label: {
                Label("Clear conversation", systemImage: "trash")
            }
            .disabled(coach.messages.isEmpty)
            Button(role: .destructive) { coach.disconnect() } label: {
                Label("Disconnect \(coach.provider.displayName)", systemImage: "key.slash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 32, height: 32)
        }
    }

    private func errorRow(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StrandPalette.statusCritical)
            VStack(alignment: .leading, spacing: 8) {
                Text(error)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let lastQuestion = coach.messages.last(where: { $0.role == .user })?.text {
                    Button {
                        Task { await coach.send(lastQuestion) }
                    } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(StrandPalette.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(StrandPalette.surfaceRaised))
    }
}

/// Pending-scroll flag for `CoachChat.followStream`, held by reference so toggling it is not a state change.
private final class StreamFollow {
    var pending = false
}

/// Keeps `atBottom` in step with the scroll position on iOS 18 and later. The end counts as reached within
/// 80 pt of it. Content growing under a still list (a streaming reply) never clears the flag by itself;
/// only the list actually moving away from the end does, so the follow cannot lose its own grip.
private struct BottomEdgeTracking: ViewModifier {
    @Binding var atBottom: Bool

    private struct Probe: Equatable {
        var offset: CGFloat
        var near: Bool
    }

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Probe.self) { geo in
                let visibleEnd = geo.contentOffset.y + geo.containerSize.height - geo.contentInsets.bottom
                return Probe(offset: geo.contentOffset.y, near: visibleEnd >= geo.contentSize.height - 80)
            } action: { old, new in
                if new.near {
                    if !atBottom { atBottom = true }
                } else if new.offset != old.offset, atBottom {
                    atBottom = false
                }
            }
        } else {
            content
        }
    }
}

// MARK: - Chips

/// Suggested questions above the composer. Equatable on the prompts, so a streaming reply or a scroll
/// redrawing the chat leaves the row alone.
private struct CoachChips: View, Equatable {
    let prompts: [String]
    let onSend: (String) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.prompts == rhs.prompts }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(prompts, id: \.self) { prompt in
                    Button { onSend(prompt) } label: {
                        Text(LocalizedStringKey(prompt))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(StrandPalette.surfaceRaised))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Composer

/// The message field and its buttons. It owns the draft, so a keystroke redraws only this view and never
/// the conversation above it. The draft survives closing the sheet: it is written to defaults once typing
/// pauses, when the composer goes away, and cleared on send.
private struct CoachComposer: View {
    let sending: Bool
    let focus: FocusState<Bool>.Binding
    let onSend: (String) -> Void

    private static let draftKey = "coach.composerDraft"

    @State private var draft = UserDefaults.standard.string(forKey: CoachComposer.draftKey) ?? ""
    @StateObject private var voice = CoachVoiceInput()

    var body: some View {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(alignment: .bottom, spacing: 8) {
            HStack(alignment: .bottom, spacing: 6) {
                TextField("Message Coach", text: $draft, axis: .vertical)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1...6)
                    .focused(focus)
                    .padding(.vertical, 11)
                    .padding(.leading, 16)
                if CoachVoiceInput.isSupported {
                    Button(action: toggleVoice) {
                        Image(systemName: voice.isRecording ? "stop.circle.fill" : "mic")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(voice.isRecording ? StrandPalette.statusCritical : StrandPalette.textSecondary)
                            .symbolEffect(.pulse, isActive: voice.isRecording)
                            .frame(width: 36, height: 42)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(voice.isRecording ? "Stop dictation" : "Dictate")
                }
            }
            .padding(.trailing, 4)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(StrandPalette.surfaceRaised))

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(empty || sending ? StrandPalette.textTertiary : StrandPalette.goldDeepText)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(empty || sending ? StrandPalette.surfaceRaised : StrandPalette.accent))
                    .animation(.snappy, value: empty)
            }
            .buttonStyle(.plain)
            .disabled(empty || sending)
            .accessibilityLabel("Send")
        }
        // Debounced save: each keystroke restarts the wait, so defaults are written once typing pauses.
        .task(id: draft) {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            persistDraft()
        }
        .onDisappear(perform: persistDraft)
    }

    private func send() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending else { return }
        onSend(trimmed)
        draft = ""
        persistDraft()
    }

    private func persistDraft() {
        if draft.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.draftKey)
        } else {
            UserDefaults.standard.set(draft, forKey: Self.draftKey)
        }
    }

    private func toggleVoice() {
        if voice.isRecording {
            voice.stopTranscribing { final in
                let t = final.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { draft = draft.isEmpty ? t : "\(draft) \(t)" }
            }
        } else if voice.authorization == .notDetermined {
            voice.requestAuthorization { state in
                if state == .authorized { voice.startTranscribing { draft = $0 } }
            }
        } else {
            voice.startTranscribing { draft = $0 }
        }
    }
}

// MARK: - Bubbles

/// Equatable on the message alone (the save action is the same every time), so while a reply streams only
/// its own bubble re-renders its Markdown; every earlier bubble is skipped.
private struct CoachBubble: View, Equatable {
    let message: ChatMessage
    let onSave: (String) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.message == rhs.message }

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 56)
                Text(message.text)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.goldDeepText)
                    .textSelection(.enabled)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20,
                                                       bottomTrailingRadius: 6, topTrailingRadius: 20,
                                                       style: .continuous)
                        .fill(StrandPalette.accent))
            }
        case .assistant:
            HStack(alignment: .bottom, spacing: 8) {
                CoachAvatar()
                Markdown(message.text)
                    .markdownTheme(.strand)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 6,
                                                       bottomTrailingRadius: 20, topTrailingRadius: 20,
                                                       style: .continuous)
                        .fill(StrandPalette.surfaceRaised))
                    .contextMenu {
                        Button { UIPasteboard.general.string = message.text } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        ShareLink(item: message.text) { Label("Share", systemImage: "square.and.arrow.up") }
                        Button { onSave(message.text) } label: {
                            Label("Save to Journal", systemImage: "square.and.pencil")
                        }
                    }
                Spacer(minLength: 32)
            }
        }
    }
}

private struct CoachAvatar: View {
    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(StrandPalette.goldDeepText)
            .frame(width: 26, height: 26)
            .background(SquircleShape().fill(StrandPalette.accent))
            .accessibilityHidden(true)
    }
}

/// A reply on its way: three dots rising and fading in turn.
private struct TypingBubble: View {
    @ObservedObject private var motion = ZoopMotionState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            CoachAvatar()
            Group {
                if motion.poseStill(reduceMotion) {
                    dots(at: 0)
                } else {
                    TimelineView(.animation) { ctx in dots(at: ctx.date.timeIntervalSinceReferenceDate) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 6,
                                               bottomTrailingRadius: 20, topTrailingRadius: 20,
                                               style: .continuous)
                .fill(StrandPalette.surfaceRaised))
            Spacer()
        }
        .accessibilityLabel("Coach is typing")
    }

    /// The three dots at time `t`; a still frame (t = 0) under Reduce Motion or quiet motion.
    private func dots(at t: Double) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                let phase = (sin((t * 2 * .pi / 1.1) - Double(i) * 0.9) + 1) / 2
                Circle()
                    .fill(StrandPalette.textSecondary)
                    .frame(width: 8, height: 8)
                    .opacity(0.35 + 0.65 * phase)
                    .offset(y: -3 * phase)
            }
        }
    }
}

// MARK: - Setup

private struct CoachSetup: View {
    @EnvironmentObject private var coach: AICoachEngine
    @State private var keyDraft = ""
    @State private var picked: AIProvider?
    @FocusState private var keyFocused: Bool

    /// Cloud providers in the order offered; the free one first.
    private let providers: [AIProvider] = [.openRouter, .openAI, .anthropic, .gemini]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .frame(width: 60, height: 60)
                        .background(SquircleShape().fill(StrandPalette.surfaceRaised))
                    Text(picked == nil ? "Set up Coach" : "Paste your key")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(picked == nil
                         ? "Coach runs on an AI provider with your own key. The key stays in this phone's Keychain."
                         : keyHint)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let picked {
                    keyStep(picked)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    providerList
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .padding(20)
            .animation(.snappy, value: picked)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Coach")
        .toolbar {
            if picked != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Back") { picked = nil; keyDraft = "" }
                        .foregroundStyle(StrandPalette.textPrimary)
                }
            }
        }
    }

    private var keyHint: String {
        switch picked {
        case .openRouter: return String(localized: "Get a free key at openrouter.ai/keys. Only free models are used, so nothing is billed.")
        case .openAI: return String(localized: "Create a key at platform.openai.com. Usage is billed by OpenAI.")
        case .anthropic: return String(localized: "Create a key at console.anthropic.com. Usage is billed by Anthropic.")
        case .gemini: return String(localized: "Create a key at aistudio.google.com. Gemini has a free tier.")
        default: return ""
        }
    }

    private var providerList: some View {
        VStack(spacing: 10) {
            ForEach(providers) { p in
                Button {
                    coach.provider = p
                    picked = p
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        keyFocused = true
                    }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: icon(p))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(StrandPalette.surfaceBase))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.displayName)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(blurb(p))
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer()
                        if p == .openRouter {
                            Text("Free")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(StrandPalette.goldDeepText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(StrandPalette.accent))
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(StrandPalette.surfaceRaised))
                }
                .buttonStyle(.plain)
            }
            NavigationLink {
                CoachView()
            } label: {
                Text("Use your own server instead")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
        }
    }

    private func keyStep(_ p: AIProvider) -> some View {
        let empty = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 18) {
            SecureField("API key", text: $keyDraft)
                .font(.system(size: 17, design: .monospaced))
                .foregroundStyle(StrandPalette.textPrimary)
                .focused($keyFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(connect)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(StrandPalette.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(keyFocused ? StrandPalette.accent : .clear, lineWidth: 1.5))

            Toggle(isOn: $coach.dataConsent) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Let Coach read my numbers")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("A summary of recovery, sleep, strain and workouts goes with each question.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(StrandPalette.accent)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(StrandPalette.surfaceRaised))

            if let error = coach.errorText, !error.isEmpty {
                Text(error)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusCritical)
            }

            Button(action: connect) {
                Text("Connect")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(empty ? StrandPalette.textTertiary : StrandPalette.surfaceBase)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Capsule().fill(empty ? StrandPalette.surfaceRaised : StrandPalette.textPrimary))
            }
            .buttonStyle(.plain)
            .disabled(empty)
        }
    }

    private func connect() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        coach.setKey(key)
        keyDraft = ""
        if coach.isConfigured { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }

    private func icon(_ p: AIProvider) -> String {
        switch p {
        case .openRouter: return "arrow.triangle.branch"
        case .openAI: return "circle.hexagongrid"
        case .anthropic: return "asterisk"
        case .gemini: return "sparkle"
        default: return "server.rack"
        }
    }

    private func blurb(_ p: AIProvider) -> String {
        switch p {
        case .openRouter: return String(localized: "Free models such as Llama, DeepSeek and Gemma")
        case .openAI: return String(localized: "GPT models, paid")
        case .anthropic: return String(localized: "Claude models, paid")
        case .gemini: return String(localized: "Gemini models, free tier available")
        default: return ""
        }
    }
}
