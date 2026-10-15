import SwiftUI
import StrandDesign

// MARK: - Steps 1–3: welcome, terms, device choice

struct OnboardingWelcomeStep: View {
    @State private var appear = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: ZoopSpacing.xl) {
                // The three Home rings filling in: a glimpse of the dashboard this flow leads to.
                HStack(spacing: ZoopSpacing.l) {
                    ring(0.79, StrandPalette.restColor)
                    ring(0.91, StrandPalette.recovery100)
                    ring(0.82, StrandPalette.effortColor)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, ZoopSpacing.xxl)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: ZoopSpacing.s) {
                    Text(verbatim: "Zoop")
                        .font(ZoopType.display)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("zoop.onboarding.welcome.tagline")
                        .font(ZoopType.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ListCard {
                    OnboardingInfoRow(icon: "lock.shield", tint: StrandPalette.statusPositive,
                                      title: String(localized: "zoop.onboarding.welcome.private.title"),
                                      message: String(localized: "zoop.onboarding.welcome.private.body"))
                        .listCardRow(isFirst: true)
                    OnboardingInfoRow(icon: "dot.radiowaves.left.and.right",
                                      title: String(localized: "zoop.onboarding.welcome.direct.title"),
                                      message: String(localized: "zoop.onboarding.welcome.direct.body"))
                        .listCardRow()
                    #if os(iOS)
                    // A sideloaded build expires and cannot read its store until the first unlock after a
                    // reboot; saying so now beats a surprise in a week (#222).
                    OnboardingInfoRow(icon: "iphone",
                                      title: String(localized: "zoop.onboarding.welcome.sideload.title"),
                                      message: String(localized: "zoop.onboarding.welcome.sideload.body"))
                        .listCardRow()
                    #endif
                }
            }
            .padding(.vertical, ZoopSpacing.xl)
            .opacity(appear ? 1 : 0)
            .offset(y: appear || reduceMotion ? 0 : 8)
        }
        .onAppear { withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.9)) { appear = true } }
    }

    private func ring(_ fraction: Double, _ tint: Color) -> some View {
        SquircleRing(fraction: appear ? fraction : 0, tint: tint, lineWidth: 6)
            .frame(width: 72, height: 72)
    }
}

struct OnboardingTermsStep: View {
    @Binding var checks: [Bool]

    var body: some View {
        OnboardingPage(title: String(localized: "zoop.onboarding.terms.title"),
                       subtitle: String(localized: "zoop.onboarding.terms.subtitle")) {
            TermsAcknowledgement(checks: $checks)
        }
    }
}

/// Only the WHOOP families Zoop fully supports are offered here. Experimental brands (Oura, Amazfit,
/// Mi Band, Garmin) and generic HR straps stay in Devices › Add a device, which says what each can do.
struct OnboardingDeviceStep: View {
    let device: OnboardingDevice?
    let select: (OnboardingDevice) -> Void

    var body: some View {
        OnboardingPage(title: String(localized: "zoop.onboarding.device.title"),
                       subtitle: String(localized: "zoop.onboarding.device.subtitle")) {
            ListCard {
                OnboardingChoiceRow(icon: "applewatch.side.right",
                                    title: WhoopModel.whoop5mg.displayName,
                                    detail: String(localized: "zoop.onboarding.device.whoop5.detail"),
                                    selected: device == .whoop(.whoop5mg)) { select(.whoop(.whoop5mg)) }
                    .listCardRow(isFirst: true)
                OnboardingChoiceRow(icon: "applewatch.side.right",
                                    title: WhoopModel.whoop4.displayName,
                                    detail: String(localized: "zoop.onboarding.device.whoop4.detail"),
                                    selected: device == .whoop(.whoop4)) { select(.whoop(.whoop4)) }
                    .listCardRow()
                OnboardingChoiceRow(icon: "iphone",
                                    title: String(localized: "zoop.onboarding.device.none.title"),
                                    detail: String(localized: "zoop.onboarding.device.none.detail"),
                                    selected: device == OnboardingDevice.none) { select(.none) }
                    .listCardRow()
            }
        }
    }
}
