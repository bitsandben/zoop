import SwiftUI
import StrandDesign

/// Terms acknowledgment gate (clickwrap). On iOS it covers an install that already finished onboarding
/// and now meets a new `Terms.currentVersion`; a fresh iOS install accepts the same text as step 2 of
/// `OnboardingWizard`, so it sees one welcome screen first rather than a legal wall. The macOS shell
/// still shows this gate first. Either way nothing pairs before acceptance; the accepted version is
/// stored locally, the on-device consent record. See `Terms` / `TERMS.md`.
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
