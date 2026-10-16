import SwiftUI
import StrandDesign

/// "Test models": sends one tiny sample prompt to each recommended model with the user's key and lists
/// how long each took and whether its reply was valid JSON. Tapping a row picks that model.
struct CoachModelTestPage: View {
    @EnvironmentObject private var coach: AICoachEngine
    @State private var results: [String: CoachModelProbe] = [:]
    @State private var running: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZoopSpacing.m) {
                Text(PlanFormat.t("zoop.coach.model.test.note"))
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                VStack(spacing: 0) {
                    ForEach(Array(coach.probeCandidates.enumerated()), id: \.element) { index, model in
                        if index > 0 { Rectangle().fill(StrandPalette.hairline).frame(height: 1) }
                        Button { coach.model = model } label: { row(model) }
                            .buttonStyle(.plain)
                    }
                }
                .background(RoundedRectangle(cornerRadius: ZoopRadius.card, style: .continuous)
                    .fill(StrandPalette.surfaceRaised))
                Button(action: runAll) {
                    Text(PlanFormat.t(running == nil ? "zoop.coach.model.test.run" : "zoop.coach.model.test.running"))
                }
                .buttonStyle(ZoopButtonStyle(.primary, fullWidth: true))
                .disabled(running != nil || !coach.isConfigured)
            }
            .padding(.horizontal, ZoopSpacing.gutter)
            .padding(.vertical, ZoopSpacing.m)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle(PlanFormat.t("zoop.coach.model.test.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { task?.cancel() }
    }

    private func row(_ model: String) -> some View {
        HStack(alignment: .center, spacing: ZoopSpacing.m) {
            VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
                Text(model)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail(model))
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: ZoopSpacing.s)
            if running == model {
                ProgressView().controlSize(.small)
            } else if coach.model == model {
                Image(systemName: "checkmark")
                    .font(ZoopType.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.accent)
            }
        }
        .padding(.horizontal, ZoopSpacing.l)
        .padding(.vertical, ZoopSpacing.m)
        .contentShape(Rectangle())
    }

    /// "Fast · 1.8 s · valid JSON", or the error, or just the tier before a run.
    private func detail(_ model: String) -> String {
        var parts: [String] = []
        if let tier = AIProvider.recommendedTier(model) { parts.append(AIProvider.tierLabel(tier)) }
        if let r = results[model] {
            if let seconds = r.seconds {
                parts.append(PlanFormat.t("zoop.coach.model.test.seconds", ZoopNumber.decimal(seconds, digits: 1)))
                parts.append(PlanFormat.t(r.validJSON ? "zoop.coach.model.test.json" : "zoop.coach.model.test.noJson"))
            } else {
                parts.append(r.error ?? PlanFormat.t("zoop.coach.model.test.failed"))
            }
        }
        return parts.joined(separator: " · ")
    }

    /// One model after another: free endpoints rate-limit bursts, which would skew the timings.
    private func runAll() {
        let models = coach.probeCandidates
        results = [:]
        task = Task {
            for model in models {
                guard !Task.isCancelled else { break }
                running = model
                results[model] = await coach.probe(model: model)
            }
            running = nil
        }
    }
}
