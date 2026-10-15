import SwiftUI
import StrandDesign

/// Coach settings: the model id typed by hand, and for OpenRouter the fallback model plus a calm note
/// when the chosen model was unavailable and the fallback answered instead.
struct CoachModelSettingsGroup: View {
    @EnvironmentObject private var coach: AICoachEngine
    @State private var modelDraft = ""
    @State private var fallbackDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            Text(PlanFormat.t("zoop.coach.model.group"))
                .font(ZoopType.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .padding(.horizontal, 6)
            VStack(alignment: .leading, spacing: ZoopSpacing.m) {
                field(PlanFormat.t("zoop.coach.model.id"), text: $modelDraft) {
                    coach.setCustomModel(modelDraft)
                }
                if coach.provider == .openRouter {
                    Rectangle().fill(StrandPalette.hairline).frame(height: 1)
                    field(PlanFormat.t("zoop.coach.model.fallback"), text: $fallbackDraft) {
                        coach.fallbackModel = fallbackDraft
                    }
                    Text(PlanFormat.t("zoop.coach.model.fallback.note"))
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let failed = coach.modelFallbackNote {
                    Text(PlanFormat.t("zoop.coach.model.fallback.used", failed, coach.fallbackModel))
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(ZoopSpacing.l)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(StrandPalette.surfaceRaised))
        }
        .onAppear {
            modelDraft = coach.model
            fallbackDraft = coach.fallbackModel
        }
        .onChange(of: coach.model) { _, value in modelDraft = value }
    }

    private func field(_ label: String, text: Binding<String>, commit: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            Text(label)
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            TextField(label, text: text)
                .font(ZoopType.body.monospaced())
                .foregroundStyle(StrandPalette.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(commit)
        }
    }
}
