import SwiftUI
import StrandDesign

/// Terms acknowledgment gate (clickwrap), shown when a finished-onboarding install meets a new
/// `Terms.currentVersion`. A fresh iOS install accepts the same text inside `OnboardingWizard`. Nothing
/// pairs before acceptance; the accepted version is stored locally. See `Terms` / `TERMS.md`.
struct TermsGateView: View {
    let onAccept: () -> Void
    @State private var checks: [Bool] = Array(repeating: false, count: Terms.attestations.count)

    var body: some View {
        VStack(spacing: 0) {
            OnboardingPage(title: String(localized: "zoop.onboarding.terms.title"),
                           subtitle: String(localized: "zoop.onboarding.terms.subtitle")) {
                TermsAcknowledgement(checks: $checks)
            }
            .padding(.horizontal, ZoopSpacing.gutter)

            ZoopButton("Accept & Continue", kind: .primary, fullWidth: true, action: onAccept)
                .disabled(!TermsAcknowledgement.allAccepted(checks))
                .keyboardShortcut(.defaultAction)
                .padding(ZoopSpacing.gutter)
        }
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
    }
}
