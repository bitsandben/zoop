import SwiftUI
import StrandDesign

// MARK: - OnboardingWizard
//
// The first-run flow (Zoop 2.0 concept §3.10): at most nine calm screens, one decision each.
//
//   1 Welcome      what Zoop is, offline and private
//   2 Terms        the clickwrap, only while the current terms are not yet accepted
//   3 Device       WHOOP 5.0 / MG, WHOOP 4.0, or no device yet
//   4 Bluetooth    why, and the current permission state       (WHOOP only)
//   5 Pair         model-specific prep, scan, bonded facts      (WHOOP only)
//   6 About you    name, birth date, sex, height, weight, units
//   7 Goals        sleep goal and training focus
//   8 First sync   what happens next, optional imports and Apple Health
//   9 Timeline     what appears after 1, 4, 14 and 28 nights
//
// Presentation and the "done" flag live with the caller (`iOSRootView` / `ContentView`); this view
// only calls `onFinished()`. Re-running it (zoop.onboarded = false) skips the terms when they are
// current and shows an already bonded strap as bonded, so it is safe to replay.

public struct OnboardingWizard: View {
    public var onFinished: () -> Void
    /// Set only for a replay, where leaving early is fine; first run has no way out but forward.
    var onClose: (() -> Void)?

    public init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    init(onFinished: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onFinished = onFinished
        self.onClose = onClose
    }

    @AppStorage("zoop.acceptedTermsVersion") private var acceptedTerms = ""

    @State private var step: OnboardingStep = OnboardingStep.debugStart ?? .welcome
    @State private var device: OnboardingDevice? = OnboardingStep.debugStart.map { _ in .whoop(.whoop4) }
    /// Decided once on appear, so accepting the terms mid-flow does not make the step vanish from
    /// the progress line under the user.
    @State private var showsTerms = false
    @State private var termsChecks = Array(repeating: false, count: Terms.attestations.count)
    @State private var pairing = OnboardingPairingState()
    /// Mirrors `live.bonded` through `OnboardingBondWatcher`. The root deliberately does not observe
    /// `LiveState` itself: it ticks with every heart beat and re-rendered the animated wizard (flicker).
    @State private var bonded = false

    public var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, ZoopSpacing.gutter)
                .padding(.top, ZoopSpacing.s)

            content
                .id(step)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
                .padding(.horizontal, ZoopSpacing.gutter)
                .frame(maxWidth: 620, maxHeight: .infinity)

            ZoopButton(LocalizedStringKey(ctaKey), kind: .primary, fullWidth: true, action: primaryAction)
                .disabled(!ctaEnabled)
                .frame(maxWidth: 620)
                .padding(.horizontal, ZoopSpacing.gutter)
                .padding(.vertical, ZoopSpacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .background(OnboardingBondWatcher(bonded: $bonded))
        .onAppear { showsTerms = acceptedTerms != Terms.currentVersion }
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:   OnboardingWelcomeStep()
        case .terms:     OnboardingTermsStep(checks: $termsChecks)
        case .device:    OnboardingDeviceStep(device: device, select: select)
        case .bluetooth: OnboardingBluetoothStep()
        case .pair:      OnboardingPairStep(pairing: $pairing, changeDevice: { go(to: .device) })
        case .profile:   OnboardingProfileStep()
        case .goals:     OnboardingGoalsStep()
        case .sync:      OnboardingSyncStep(hasStrap: device?.whoopModel != nil)
        case .timeline:  OnboardingTimelineStep()
        }
    }

    /// The steps this run walks through, in order. Bluetooth and pairing only exist for a strap.
    private var path: [OnboardingStep] {
        OnboardingStep.allCases.filter { s in
            switch s {
            case .terms: return showsTerms
            case .bluetooth, .pair: return device?.whoopModel != nil
            default: return true
            }
        }
    }

    private var progress: Double {
        guard let i = path.firstIndex(of: step), path.count > 1 else { return 0 }
        return Double(i) / Double(path.count - 1)
    }

    // MARK: Chrome

    private var topBar: some View {
        VStack(spacing: ZoopSpacing.m) {
            HStack {
                if step != .welcome {
                    Button(action: back) {
                        Image(systemName: "chevron.left")
                            .font(ZoopType.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(StrandPalette.surfaceRaised))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Back"))
                } else if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(ZoopType.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(StrandPalette.surfaceRaised))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Close"))
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
                Spacer()
                if let target = step.skipTarget {
                    Button("zoop.onboarding.later") { go(to: target) }
                        .buttonStyle(ZoopButtonStyle(.tertiary))
                }
            }
            OnboardingProgressLine(progress: progress)
        }
    }

    private var ctaKey: String {
        switch step {
        case .welcome:  return "zoop.onboarding.cta.start"
        case .terms:    return "zoop.onboarding.cta.accept"
        case .pair:     return bonded ? "zoop.onboarding.cta.continue" : "zoop.onboarding.cta.pairLater"
        case .timeline: return "zoop.onboarding.cta.finish"
        default:        return "zoop.onboarding.cta.continue"
        }
    }

    private var ctaEnabled: Bool {
        switch step {
        case .terms:  return TermsAcknowledgement.allAccepted(termsChecks)
        case .device: return device != nil
        default:      return true
        }
    }

    // MARK: Navigation

    private func primaryAction() {
        if step == .terms { acceptedTerms = Terms.currentVersion }
        guard let i = path.firstIndex(of: step), i + 1 < path.count else { onFinished(); return }
        go(to: path[i + 1])
    }

    private func back() {
        guard let i = path.firstIndex(of: step), i > 0 else { return }
        go(to: path[i - 1])
    }

    private func go(to target: OnboardingStep) {
        withAnimation(StrandMotion.gentle) { step = target }
    }

    /// Choosing a different strap after a scan already ran in this flow asks the pair step to restart
    /// the scan for the new family, exactly as the old in-scan model switch did.
    private func select(_ choice: OnboardingDevice) {
        device = choice
        guard let model = choice.whoopModel else { return }
        pairing.choose(model)
    }
}

/// Every step the flow knows, in display order.
enum OnboardingStep: Int, CaseIterable {
    case welcome, terms, device, bluetooth, pair, profile, goals, sync, timeline

    /// Where "Later" jumps to, or nil where the step cannot be skipped. Terms are legal and the device
    /// choice already offers "no device", so neither has one; the pair step's own CTA is its skip.
    var skipTarget: OnboardingStep? {
        switch self {
        case .bluetooth: return .profile
        case .profile:   return .goals
        case .goals:     return .sync
        case .sync:      return .timeline
        case .welcome, .terms, .device, .pair, .timeline: return nil
        }
    }
}

extension OnboardingStep {
    /// DEBUG only: `--onboarding-step <case>` opens the flow at that step (with WHOOP 4.0 chosen) so the
    /// simulator can screenshot every step without driving taps. Always nil in Release.
    static var debugStart: OnboardingStep? {
        #if DEBUG
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--onboarding-step"), i + 1 < args.count else { return nil }
        return allCases.first { "\($0)" == args[i + 1] }
        #else
        return nil
        #endif
    }
}

/// What the user said they will wear.
enum OnboardingDevice: Hashable {
    case whoop(WhoopModel)
    case none

    var whoopModel: WhoopModel? {
        if case .whoop(let m) = self { return m }
        return nil
    }
}

/// Hidden observer that forwards `live.bonded`; it re-renders on every live tick at no visible cost.
private struct OnboardingBondWatcher: View {
    @EnvironmentObject private var live: LiveState
    @Binding var bonded: Bool

    var body: some View {
        Color.clear
            .onAppear { bonded = live.bonded }
            .onChangeCompat(of: live.bonded) { bonded = $0 }
    }
}

#if DEBUG
private struct OnboardingPreview: View {
    @StateObject private var model = AppModel()
    var body: some View {
        OnboardingWizard(onFinished: {})
            .environmentObject(model)
            .environmentObject(model.live)
            .environmentObject(model.profile)
    }
}

#Preview("Onboarding") { OnboardingPreview() }
#endif
