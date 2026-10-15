import SwiftUI
import StrandDesign

// The pieces of the plan builder conversation: the coach's lines (avatar, quiet thinking line, text),
// the user's accent bubbles, quick replies, the weekday picker and the composer.

/// The small mark beside the coach's lines.
struct PlanCoachAvatar: View {
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: "sparkles")
            .font(ZoopType.caption.weight(.bold))
            .foregroundStyle(StrandPalette.goldDeepText)
            .frame(width: size, height: size)
            .background(SquircleShape().fill(StrandPalette.accent))
            .accessibilityHidden(true)
    }
}

/// "Für 9 Sekunden nachgedacht", which opens the model's reasoning when it sent any.
struct PlanThoughtLine: View {
    let thought: PlanChatModel.Thought
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            Button {
                withAnimation(.snappy) { open.toggle() }
            } label: {
                HStack(spacing: ZoopSpacing.xs) {
                    Text(PlanFormat.t("zoop.planchat.thought", "\(max(1, thought.seconds))"))
                    if thought.reasoning != nil {
                        Image(systemName: open ? "chevron.up" : "chevron.down")
                            .font(ZoopType.caption.weight(.semibold))
                    }
                }
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(thought.reasoning == nil)
            if open, let reasoning = thought.reasoning {
                Text(reasoning)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, ZoopSpacing.s)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(StrandPalette.hairline).frame(width: 2)
                    }
            }
        }
    }
}

/// One message: coach lines flush left with the avatar, the user's answers in accent bubbles.
struct PlanChatRow<Card: View>: View {
    let message: PlanChatModel.Message
    @ViewBuilder let card: () -> Card

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 56)
                if case .text(let text) = message.body {
                    Text(text)
                        .font(ZoopType.body)
                        .foregroundStyle(StrandPalette.goldDeepText)
                        .padding(.horizontal, ZoopSpacing.l)
                        .padding(.vertical, ZoopSpacing.s + 2)
                        .background(RoundedRectangle(cornerRadius: ZoopRadius.tile, style: .continuous)
                            .fill(StrandPalette.accent))
                }
            }
        case .assistant:
            VStack(alignment: .leading, spacing: ZoopSpacing.s) {
                if let thought = message.thought { PlanThoughtLine(thought: thought) }
                if case .text(let text) = message.body {
                    HStack(alignment: .top, spacing: ZoopSpacing.s) {
                        PlanCoachAvatar()
                        Text(text)
                            .font(ZoopType.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(.top, 3)
                        Spacer(minLength: ZoopSpacing.l)
                    }
                } else {
                    card()
                }
            }
        }
    }
}

/// While the provider answers.
struct PlanThinkingRow: View {
    var body: some View {
        HStack(spacing: ZoopSpacing.s) {
            PlanCoachAvatar()
            ProgressView().controlSize(.small)
            Text(PlanFormat.t("zoop.planchat.thinking"))
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }
}

/// Tap-to-answer chips; one tap sends.
struct PlanQuickReplies: View {
    let replies: [String]
    let onSend: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ZoopSpacing.s) {
                ForEach(replies, id: \.self) { reply in
                    Button { onSend(reply) } label: {
                        Text(reply)
                            .font(ZoopType.caption.weight(.medium))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(StrandPalette.surfaceRaised))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, ZoopSpacing.xs)
        }
    }
}

/// The days question: pick the weekdays, then send them as one answer ("3 Tage: Mo., Mi., Fr.").
struct PlanWeekdayPicker: View {
    @Binding var selected: Set<Int>
    let onSend: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(LiftProgramPlanSheet.orderedWeekdays, id: \.self) { day in
                let on = selected.contains(day)
                Button {
                    if on { selected.remove(day) } else { selected.insert(day) }
                } label: {
                    Text(PlanFormat.shortWeekday(day).prefix(2))
                        .font(ZoopType.caption.weight(.semibold))
                        .foregroundStyle(on ? StrandPalette.goldDeepText : StrandPalette.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(Circle().fill(on ? StrandPalette.accent : StrandPalette.surfaceRaised))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PlanFormat.weekday(day))
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
            Button {
                let days = LiftProgramPlanSheet.orderedWeekdays.filter(selected.contains)
                onSend(PlanFormat.t("zoop.planchat.days.answer", "\(days.count)",
                                    days.map(PlanFormat.shortWeekday).joined(separator: ", ")))
            } label: {
                Image(systemName: "arrow.up")
                    .font(ZoopType.caption.weight(.bold))
                    .foregroundStyle(selected.isEmpty ? StrandPalette.textTertiary : StrandPalette.goldDeepText)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(selected.isEmpty ? StrandPalette.surfaceRaised : StrandPalette.accent))
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty)
            .accessibilityLabel(Text(PlanFormat.t("zoop.planchat.send")))
        }
    }
}

/// The answer field.
struct PlanComposer: View {
    let placeholder: String
    let disabled: Bool
    let focus: FocusState<Bool>.Binding
    let onSend: (String) -> Void
    @State private var draft = ""

    var body: some View {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(alignment: .bottom, spacing: ZoopSpacing.s) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .font(ZoopType.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1...5)
                .focused(focus)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.vertical, 11)
                .padding(.horizontal, ZoopSpacing.l)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(StrandPalette.surfaceRaised))
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(ZoopType.body.weight(.bold))
                    .foregroundStyle(empty || disabled ? StrandPalette.textTertiary : StrandPalette.goldDeepText)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(empty || disabled ? StrandPalette.surfaceRaised : StrandPalette.accent))
            }
            .buttonStyle(.plain)
            .disabled(empty || disabled)
            .accessibilityLabel(Text(PlanFormat.t("zoop.planchat.send")))
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !disabled else { return }
        onSend(text)
        draft = ""
    }
}
