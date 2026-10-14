import SwiftUI
import StrandDesign

/// Runs the onboarding flow again over the current screen. Presented locally rather than by clearing
/// `zoop.onboarded`: the root overlay would sit underneath whatever sheet hosts this button. Nothing is
/// reset; each step shows what is already stored, the terms step is skipped while current, and an
/// already bonded strap shows as bonded.
struct OnboardingReplayButton: View {
    @EnvironmentObject private var model: AppModel
    #if os(iOS)
    @EnvironmentObject private var health: HealthKitBridge
    #endif
    @State private var presented = false

    var body: some View {
        Button("zoop.onboarding.replay") { presented = true }
            .buttonStyle(ZoopButtonStyle(.tertiary))
            #if os(iOS)
            .fullScreenCover(isPresented: $presented) { wizard }
            #else
            .sheet(isPresented: $presented) { wizard.frame(minWidth: 520, minHeight: 680) }
            #endif
    }

    private var wizard: some View {
        OnboardingWizard(onFinished: { presented = false }, onClose: { presented = false })
            .environmentObject(model)
            .environmentObject(model.live)
            .environmentObject(model.profile)
            #if os(iOS)
            .environmentObject(health)
            #endif
    }
}
