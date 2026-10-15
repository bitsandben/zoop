import SwiftUI
import StrandDesign

/// Root sidebar shell, with the onboarding/pairing wizard overlaid until complete and a "What's New" sheet after an update.
struct ContentView: View {
    @AppStorage("zoop.onboarded") private var onboarded = false
    @AppStorage("zoop.lastSeenChangelogVersion") private var lastSeenChangelog = ""
    @AppStorage("zoop.acceptedTermsVersion") private var acceptedTerms = ""
    /// Local timestamp of the last terms acceptance (the on-device consent record).
    @AppStorage("zoop.acceptedTermsAt") private var acceptedTermsAt = ""
    @State private var showWhatsNew = false

    var body: some View {
        ZStack {
            RootView()
            if !onboarded {
                OnboardingWizard(onFinished: {
                    onboarded = true
                    // A brand-new user just saw the expectations in onboarding; mark the changelog current.
                    lastSeenChangelog = AppChangelog.currentVersion
                })
                .transition(.opacity)
                .zIndex(1)
            }
            // Terms gate sits over everything (before onboarding, pairing, Bluetooth) until the current version is accepted.
            if acceptedTerms != Terms.currentVersion {
                TermsGateView(onAccept: {
                    acceptedTermsAt = ISO8601DateFormatter().string(from: Date())
                    acceptedTerms = Terms.currentVersion
                })
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        // Calm decelerating curve (cubic-bezier 0.22,1,0.36,1, ~0.42s) for the full-screen onboarding / terms overlays.
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.42), value: onboarded)
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.42), value: acceptedTerms)
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView(onClose: {
                lastSeenChangelog = AppChangelog.currentVersion
                showWhatsNew = false
            })
        }
        // Do not pop What's New over the Terms gate: gate on terms being current and re-check on acceptance.
        .onAppear {
            showWhatsNewIfDue()
            // Seed the current What's New into the Updates inbox (idempotent per version).
            UpdateStore.shared.seedWhatsNewIfNeeded()
            // Update check runs on the same condition as showWhatsNewIfDue: a default-on check must not touch the
            // network before the Terms gate is accepted (#1659).
            if onboarded && acceptedTerms == Terms.currentVersion {
                UpdateWatch.runIfDue(currentVersion: UpdateWatch.installedVersion, sideloadHint: false)
            }
        }
        .onChangeCompat(of: acceptedTerms) { _ in showWhatsNewIfDue() }
    }

    private func showWhatsNewIfDue() {
        // Existing users whose last-seen version is behind the current one.
        if onboarded && acceptedTerms == Terms.currentVersion
            && lastSeenChangelog != AppChangelog.currentVersion {
            showWhatsNew = true
        }
    }
}
