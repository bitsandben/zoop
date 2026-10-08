import SwiftUI
import StrandDesign

// MARK: - Coach settings (iOS)
//
// The settings page pushed from the Coach chat sheet. The same choices as `CoachSettingsView` — model,
// what the coach may read, its instructions, the morning brief — laid out as grouped rows with an icon
// well per row, like the rest of Settings, plus the connection actions that live in the chat's menu.

struct CoachSettingsPage: View {
    @EnvironmentObject private var coach: AICoachEngine
    @Environment(\.dismiss) private var dismiss

    @State private var briefEnabled = CoachBriefScheduler.isEnabled
    @State private var briefMinutes = CoachBriefScheduler.timeMinutes
    @State private var briefGenerating = false
    @State private var briefStatus: String?
    @State private var refreshing = false
    @State private var showClearConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                providerCard

                group("Privacy") {
                    toggleRow(icon: coach.dataConsent ? "lock.open.fill" : "lock.fill",
                              title: "Read my numbers",
                              subtitle: coach.dataConsent
                                ? "Recovery, sleep, strain, HRV and workouts go with each question."
                                : "Off. Coach answers in general terms.",
                              isOn: $coach.dataConsent)
                    if coach.dataConsent {
                        divider
                        toggleRow(icon: "checklist",
                                  title: "Patterns and Lab Book",
                                  subtitle: "Adds a short summary of your strongest patterns. Never raw readings.",
                                  isOn: $coach.includeOnDeviceSignals)
                        if coach.provider == .gemini {
                            divider
                            toggleRow(icon: "photo",
                                      title: "Send a chart image",
                                      subtitle: "Gemini also sees a picture of your trends.",
                                      isOn: $coach.multimodalChartEnabled)
                        }
                    }
                }

                group("Morning brief") {
                    toggleRow(icon: "sunrise.fill",
                              title: "Daily brief",
                              subtitle: "A notification with today's readiness and a plan.",
                              isOn: $briefEnabled)
                    if briefEnabled {
                        divider
                        row(icon: "clock") {
                            Text("Time")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            DatePicker("", selection: briefTimeBinding, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                        divider
                        Button(action: generateBriefNow) {
                            row(icon: "sparkles") {
                                Text(briefGenerating ? "Writing…" : "Write today's brief now")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(StrandPalette.accent)
                                Spacer()
                                if briefGenerating { ProgressView().controlSize(.small) }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(briefGenerating)
                    }
                }
                if let briefStatus {
                    Text(briefStatus)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.top, -16)
                }

                group("Personality") {
                    NavigationLink {
                        CoachInstructionsPage()
                    } label: {
                        row(icon: "text.bubble") {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Coach instructions")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(coach.hasCustomSystemPrompt ? "Your own" : "Default")
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                group("Conversation") {
                    Button { showClearConfirm = true } label: {
                        row(icon: "trash", tint: StrandPalette.statusCritical) {
                            Text("Clear conversation")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(StrandPalette.statusCritical)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(coach.messages.isEmpty)
                    divider
                    Button {
                        coach.disconnect()
                        dismiss()
                    } label: {
                        row(icon: "key.slash", tint: StrandPalette.statusCritical) {
                            Text("Disconnect \(coach.provider.displayName)")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(StrandPalette.statusCritical)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle("Coach settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await coach.refreshModelsIfStale() }
        .onChange(of: briefEnabled) { _, on in
            CoachBriefScheduler.setEnabled(on, generateBrief: { await coach.generateBrief() }) { outcome in
                if outcome == .denied {
                    briefEnabled = false
                    briefStatus = String(localized: "Notifications are off for Zoop. Turn them on in iOS Settings first.")
                }
            }
        }
        .confirmationDialog("Clear conversation?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { coach.clearConversation() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Provider

    private var providerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(StrandPalette.goldDeepText)
                    .frame(width: 52, height: 52)
                    .background(SquircleShape().fill(StrandPalette.accent))
                VStack(alignment: .leading, spacing: 3) {
                    Text(coach.provider.displayName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    HStack(spacing: 6) {
                        Circle().fill(StrandPalette.accent).frame(width: 7, height: 7)
                        Text("Connected")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                Spacer()
            }
            Menu {
                Picker("Model", selection: $coach.model) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Text(coach.model)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(StrandPalette.surfaceBase))
            }
            Button {
                Task {
                    refreshing = true
                    await coach.refreshModels()
                    refreshing = false
                }
            } label: {
                HStack(spacing: 6) {
                    if refreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(coach.provider == .openRouter ? "Load current free models" : "Load current models")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
            }
            .buttonStyle(.plain)
            .disabled(refreshing || !coach.hasKey)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(StrandPalette.surfaceRaised))
    }

    private var models: [String] {
        var list = coach.availableModels.isEmpty ? coach.provider.modelOptions : coach.availableModels
        if !list.contains(coach.model) { list.insert(coach.model, at: 0) }
        return list
    }

    // MARK: Building blocks

    private func group<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .padding(.horizontal, 6)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(StrandPalette.surfaceRaised))
        }
    }

    private func row<Content: View>(icon: String, tint: Color = StrandPalette.textPrimary,
                                    @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(Circle().fill(StrandPalette.surfaceBase))
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func toggleRow(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey,
                           isOn: Binding<Bool>) -> some View {
        row(icon: icon) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(subtitle)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(StrandPalette.accent)
        }
    }

    private var divider: some View {
        Rectangle().fill(StrandPalette.hairline).frame(height: 1).padding(.leading, 66)
    }

    // MARK: Brief

    private var briefTimeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = briefMinutes / 60
                c.minute = briefMinutes % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let m = (c.hour ?? 7) * 60 + (c.minute ?? 0)
                briefMinutes = m
                CoachBriefScheduler.setTimeMinutes(m, generateBrief: { await coach.generateBrief() })
            }
        )
    }

    private func generateBriefNow() {
        Task {
            briefGenerating = true
            briefStatus = nil
            defer { briefGenerating = false }
            if let text = await CoachBriefScheduler.generateNow(generateBrief: { await coach.generateBrief() }) {
                coach.appendGeneratedBrief(text)
            } else {
                briefStatus = String(localized: "Couldn't write a brief right now. Check your key and that Coach may read your numbers.")
            }
        }
    }
}

// MARK: - Instructions

/// The coach's system prompt, full screen, with a reset to the default.
private struct CoachInstructionsPage: View {
    @EnvironmentObject private var coach: AICoachEngine
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How Coach should think and talk. Applies from your next message.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            TextEditor(text: $draft)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(StrandPalette.surfaceRaised))
        }
        .padding(16)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle("Coach instructions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reset") {
                    coach.resetSystemPrompt()
                    draft = coach.customSystemPrompt
                }
                .disabled(!coach.hasCustomSystemPrompt)
            }
        }
        .onAppear { draft = coach.customSystemPrompt }
        .onChange(of: draft) { _, value in coach.customSystemPrompt = value }
    }
}
