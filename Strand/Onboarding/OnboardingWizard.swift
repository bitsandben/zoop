import SwiftUI
import UniformTypeIdentifiers
import StrandDesign
import WhoopStore
import UserNotifications

// MARK: - OnboardingWizard
//
// A full-screen, paged onboarding + pairing flow for NOOP. Cinematic and calm:
// a dark surfaceBase substrate with a slow ambient glow, a bottom progress "thread"
// that fills as you advance, Back always available, and a forward CTA per step.
//
// Steps:
//  1 Welcome           — NOOP + "all your data, none of the cloud"
//  2 What it does      — 3 calm value slides
//  3 About you         — name, birthday, sex, height, weight: one question per step
//                        (OnboardingProfileSteps.swift), bound to ProfileStore
//  4 Bluetooth priming — explain BEFORE the OS prompt
//  5 Wear & wake       — put your strap on, make sure it's charged
//  6 Scan              — radar sweep; auto-scans, Scan retries via model.scan()
//  7 Bonding           — celebration when live.bonded (a RecoveryRing blooms in)
//  8 Import (optional)  — WHOOP / Apple Health import from the wizard
//  9 Done              — "You're all set" → onFinished()
//
// Presentation is wired centrally; this view only calls onFinished() when complete.

public struct OnboardingWizard: View {

    /// Called when the user finishes (or skips to the end of) onboarding.
    public var onFinished: () -> Void

    public init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    // NOTE: the root deliberately does NOT observe the fast-updating model/live/profile
    // env objects — doing so re-rendered the whole animated wizard on every HR tick and
    // caused flicker. Child steps observe what they need; a hidden BondWatcher (below)
    // handles the bond→celebration transition without re-rendering the root. The profile is the one
    // exception: it changes only when the user answers a question, and the name step's button reads it.
    @EnvironmentObject private var profile: ProfileStore

    private enum Step: Int, CaseIterable {
        case welcome, what, expectations, name, birthday, sex, height, weight, bluetooth, wear, scan, bonded, importData, notifications, appearance, done

        var isFirst: Bool { self == .welcome }
        var isLast: Bool { self == .done }
    }

    @State private var step: Step = .welcome

    public var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                // Top chrome: a small back affordance + a step counter.
                topBar
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                // The paged content.
                ZStack {
                    switch step {
                    case .welcome:    WelcomeStep()
                    case .what:       WhatItDoesStep()
                    case .expectations: ExpectationsStep()
                    case .name:       OnboardingNameStep(advance: advance)
                    case .birthday:   OnboardingBirthdayStep()
                    case .sex:        OnboardingSexStep()
                    case .height:     OnboardingHeightStep()
                    case .weight:     OnboardingWeightStep()
                    case .bluetooth:  BluetoothStep()
                    case .wear:       WearStep()
                    case .scan:       ScanStep(advance: advance)
                    case .bonded:     BondedStep()
                    case .importData: ImportStep()
                    case .notifications: NotificationsStep()
                    case .appearance: AppearanceStep()
                    case .done:       DoneStep()
                    }
                }
                .frame(maxWidth: 620, maxHeight: .infinity)
                .transition(stepTransition)
                .id(step)                       // re-runs the transition per step
                .padding(.horizontal, 24)

                // Bottom: the thread (progress) + the forward CTA.
                bottomBar
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        // Isolated live observation — a hidden watcher slides Scan → celebration on bond
        // without subscribing the whole wizard to per-tick updates.
        .background(BondWatcher(onBonded: handleBond))
    }

    private func handleBond() {
        if step == .scan { withAnimation(StrandMotion.hero) { step = .bonded } }
    }

    // MARK: Backgrounds

    /// A flat near-black canvas, as in the redesign concept: no glow and no gradient.
    private var background: some View {
        StrandPalette.surfaceBase.ignoresSafeArea()
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            if step.isFirst {
                Color.clear.frame(width: 40, height: 40)
            } else {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(StrandPalette.surfaceRaised))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }

            Spacer()

            Text("\(step.rawValue + 1) / \(Step.allCases.count)")
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(StrandPalette.textSecondary)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Capsule().fill(StrandPalette.surfaceRaised))
        }
    }

    // MARK: Bottom bar (the thread + CTA)

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 22) {
            ThreadProgress(progress: progress)
                .frame(height: 4)
                .frame(maxWidth: 620)

            HStack(spacing: 14) {
                PrimaryButton(title: ctaTitle, systemImage: ctaIcon, action: primaryAction)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: 620)
        }
    }

    private var progress: Double {
        guard Step.allCases.count > 1 else { return 1 }
        return Double(step.rawValue) / Double(Step.allCases.count - 1)
    }

    private var ctaTitle: String {
        switch step {
        case .welcome:    return String(localized: "Get Started")
        case .what:       return String(localized: "Continue")
        case .expectations: return String(localized: "I understand")
        case .bluetooth:  return String(localized: "Continue")
        case .wear:       return String(localized: "I'm wearing it")
        case .scan:       return String(localized: "Continue")
        case .bonded:     return String(localized: "Continue")
        case .name:       return profile.name.trimmingCharacters(in: .whitespaces).isEmpty
                                    ? String(localized: "Skip") : String(localized: "Continue")
        case .birthday, .sex, .height, .weight: return String(localized: "Continue")
        case .importData: return String(localized: "Continue")
        case .notifications: return String(localized: "Continue")
        case .appearance: return String(localized: "Continue")
        case .done:       return String(localized: "Enter Zoop")
        }
    }

    private var ctaIcon: String? {
        switch step {
        case .done:    return "arrow.right"
        case .bonded:  return "checkmark"
        default:       return nil
        }
    }

    private func primaryAction() {
        if step.isLast {
            onFinished()
        } else {
            advance()
        }
    }

    // MARK: Navigation

    /// Leaving the Notifications step is the one point in onboarding where we actually ask the OS for
    /// notification permission — everything before this only explained why (the `NotificationsStep`
    /// card). Without this, NOOP never showed up under Settings → Notifications at all unless a user
    /// later found and enabled one of the opt-in automations (wind-down, battery, illness) buried in
    /// More → Alarms/Automations, each of which lazily requests on its own toggle. Mirrors the Android
    /// onboarding's `OnboardingPage.Notifications` step (`OnboardingScreen.kt`): request only if not
    /// already determined (so a re-run/upgrade doesn't re-prompt), and advance once the OS dialog is
    /// dismissed either way — the per-feature toggles still handle a later denial on their own.
    private func advance() {
        guard step != .notifications else {
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                guard settings.authorizationStatus == .notDetermined else {
                    Task { @MainActor in advanceStep() }
                    return
                }
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                    Task { @MainActor in advanceStep() }
                }
            }
            return
        }
        advanceStep()
    }

    private func advanceStep() {
        guard let next = Step(rawValue: step.rawValue + 1) else { onFinished(); return }
        withAnimation(StrandMotion.gentle) { step = next }
    }

    private func back() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation(StrandMotion.gentle) { step = prev }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }
}

/// Hidden, isolated observer — re-renders on live updates (it's just Color.clear, so no
/// visible cost) and fires `onBonded` when the strap bonds, keeping the main wizard body
/// out of the per-tick re-render path that caused flicker.
private struct BondWatcher: View {
    @EnvironmentObject private var live: LiveState
    let onBonded: () -> Void
    var body: some View {
        Color.clear.onChangeCompat(of: live.bonded) { newValue in if newValue { onBonded() } }
    }
}

// MARK: - Step 1 · Welcome

private struct WelcomeStep: View {
    @State private var appear = false
    var body: some View {
        StepShell {
            VStack(spacing: 28) {
                Spacer(minLength: 24)
                // The three score rings from Home, filling in as the step appears.
                HStack(spacing: 14) {
                    OnboardingRing(fraction: appear ? 0.79 : 0, tint: StrandPalette.restColor, label: "Sleep")
                    OnboardingRing(fraction: appear ? 0.91 : 0, tint: StrandPalette.recovery100, label: "Recovery")
                    OnboardingRing(fraction: appear ? 0.82 : 0, tint: StrandPalette.effortColor, label: "Strain")
                }
                .padding(.bottom, 8)
                VStack(spacing: 10) {
                    Text(verbatim: "Zoop")
                        .font(StrandFont.display(64))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Your strap data, on your phone")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .multilineTextAlignment(.center)
                    Text("Recovery, sleep and strain, read directly from your strap. Nothing leaves \(Platform.deviceNounPhrase).")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 10)
                Spacer(minLength: 24)
            }
        }
        .onAppear { withAnimation(.easeOut(duration: 1.1)) { appear = true } }
    }
}

/// A small squircle ring with its name under it, for the onboarding illustrations.
private struct OnboardingRing: View {
    let fraction: Double
    let tint: Color
    let label: LocalizedStringKey
    var size: CGFloat = 84

    var body: some View {
        VStack(spacing: 10) {
            SquircleRing(fraction: fraction, tint: tint, lineWidth: 6)
                .frame(width: size, height: size)
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .accessibilityHidden(true)
    }
}

/// The concept's list row: a charcoal card with the icon in a black well, a title and a body line.
private struct OnboardingRow: View {
    let icon: String
    var tint: Color = StrandPalette.textPrimary
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
                .background(Circle().fill(StrandPalette.surfaceBase))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.top, 2)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(message)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: 520, alignment: .leading)
        .background(ZoopPanelSurface(cornerRadius: 20))
    }
}

// MARK: - Step 2 · What it does

private struct WhatItDoesStep: View {
    private struct Slide: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Color
        let title: String
        let body: String
    }

    private let slides: [Slide] = [
        .init(icon: "circle.dashed.inset.filled",
              tint: StrandPalette.accent,
              title: String(localized: "Daily scores"),
              body: String(localized: "Recovery, strain and sleep, calculated from your HRV, resting heart rate and sleep.")),
        .init(icon: "waveform.path.ecg",
              tint: StrandPalette.accent,
              title: String(localized: "Live heart rate"),
              body: String(localized: "Connect a WHOOP, a heart-rate strap or a gym machine and watch each beat in real time: heart rate, variability and zones as they happen. Already have history elsewhere? Import it from WHOOP, Apple Health, Oura, Fitbit or Garmin.")),
        .init(icon: "lock.shield",
              tint: StrandPalette.statusPositive,
              title: String(localized: "Offline"),
              body: String(localized: "No account and no cloud. Your data stays on \(Platform.deviceNounPhrase).")),
    ]

    var body: some View {
        StepShell(title: String(localized: "What Zoop does")) {
            VStack(spacing: 14) {
                ForEach(Array(slides.enumerated()), id: \.element.id) { index, slide in
                    SlideRow(slide: slide, index: index)
                }
            }
        }
    }

    private struct SlideRow: View {
        let slide: Slide
        let index: Int
        @State private var shown = false
        var body: some View {
            OnboardingRow(icon: slide.icon, tint: slide.tint, title: slide.title, message: slide.body)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onAppear {
                withAnimation(StrandMotion.gentle.delay(Double(index) * 0.10)) { shown = true }
            }
        }
    }
}

// MARK: - Step 2.5 · What to expect (independent / experimental / 5-MG framing)

private struct ExpectationsStep: View {
    @State private var shown = false
    var body: some View {
        StepShell(title: String(localized: "Good to know")) {
            VStack(spacing: 12) {
                ForEach(Array(AppChangelog.expectations.enumerated()), id: \.element.id) { index, e in
                    OnboardingRow(icon: e.icon, tint: StrandPalette.accent, title: e.title, message: e.body)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 8)
                    .animation(StrandMotion.gentle.delay(Double(index) * 0.08), value: shown)
                }

                #if os(iOS)
                // The iPhone-only reality: this is a sideloaded build, so set the re-sign + unlock
                // expectation up front rather than letting it surprise people later (#222 / cert expiry).
                expectationRow(
                    icon: "iphone.gen3",
                    title: String(localized: "Installed outside the App Store"),
                    body: String(localized: "On iPhone this is a sideloaded build. Re-sign it about every 7 days on a free Apple ID (longer on a paid account). After your phone reboots, unlock it once so Zoop can read and sync its data.")
                )
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 8)
                .animation(StrandMotion.gentle.delay(Double(AppChangelog.expectations.count) * 0.08), value: shown)
                #endif
            }
        }
        .onAppear { shown = true }
    }

    /// One expectation callout, matching the data-driven rows above so the iOS-only addition is visually
    /// identical to the rest of the list.
    private func expectationRow(icon: String, title: String, body: String) -> some View {
        OnboardingRow(icon: icon, tint: StrandPalette.accent, title: title, message: body)
    }
}

// MARK: - Step 3 · Bluetooth priming

private struct BluetoothStep: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Low Power Mode / "Reduce motion in NOOP" pose these looping glows still too. Onboarding is
    /// first-run only, but a `repeatForever` is a `repeatForever` wherever it lives.
    @ObservedObject private var motion = ZoopMotionState.shared
    private var poseStill: Bool { motion.poseStill(reduceMotion) }
    var body: some View {
        StepShell(title: String(localized: "Bluetooth access"),
                  subtitle: String(localized: "\(Platform.deviceNoun) asks for permission next.")) {
            VStack(spacing: 24) {
                ZStack {
                    SquircleShape()
                        .stroke(StrandPalette.accent.opacity(0.35), lineWidth: 2)
                        .frame(width: 120, height: 120)
                        .scaleEffect(pulse ? 1.22 : 0.92)
                        .opacity(pulse ? 0 : 0.8)
                    SquircleRing(fraction: 1, tint: StrandPalette.accent, lineWidth: 6)
                        .frame(width: 100, height: 100)
                    Image(systemName: "wave.3.right")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .frame(height: 140)

                InfoCard(
                    icon: "lock.fill",
                    tint: StrandPalette.statusPositive,
                    title: String(localized: "Nothing leaves your \(Platform.deviceNoun)"),
                    message: String(localized: "Zoop connects to your strap directly over Bluetooth. No server is involved.")
                )

                Text("Tap Allow when asked.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
        }
        .onAppear { if !poseStill { withAnimation(StrandMotion.breathe) { pulse = true } } }
    }
}

// MARK: - Step 4 · Wear & wake

private struct WearStep: View {
    var body: some View {
        StepShell(title: String(localized: "Put your strap on"),
                  subtitle: String(localized: "And make sure it's charged.")) {
            VStack(spacing: 22) {
                ZStack {
                    SquircleRing(fraction: 0.66, tint: StrandPalette.restColor, lineWidth: 6)
                        .frame(width: 120, height: 120)
                    Image(systemName: "applewatch.side.right")
                        .font(.system(size: 50, weight: .regular))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .frame(height: 140)

                VStack(spacing: 12) {
                    Checkline(text: String(localized: "Wear it snug on your wrist or bicep, sensor against skin."))
                    Checkline(text: String(localized: "Give it a few minutes of charge if the battery is low."))
                    Checkline(text: String(localized: "Keep it within about a metre of \(Platform.deviceNounPhrase)."))
                }
                .frame(maxWidth: 440)
            }
        }
    }
}

// MARK: - Step 5 · Scan (radar sweep + reassurance)

private struct ScanStep: View {
    let advance: () -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    @State private var scanning = false
    @State private var showHelp = false

    /// Which strap to look for — shared with the Live screen via the same key.
    @AppStorage("selectedWhoopModel") private var selectedModelRaw = WhoopModel.whoop4.rawValue
    private var selectedModel: WhoopModel { WhoopModel(rawValue: selectedModelRaw) ?? .whoop4 }

    var body: some View {
        StepShell(title: String(localized: "Find your strap"),
                  subtitle: live.bonded ? String(localized: "Bonded. You're set.") : String(localized: "Pick your strap below, then tap Scan. Zoop will find it.")) {
            VStack(spacing: 24) {
                RadarSweep(active: scanning && !live.bonded, bonded: live.bonded)
                    .frame(width: 220, height: 220)

                statusLine

                if !live.bonded {
                    VStack(spacing: 8) {
                        Text("Which strap are you pairing?").font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                        SegmentedPillControl(
                            WhoopModel.allCases,
                            selection: Binding(
                                get: { selectedModel },
                                set: { restartScan(for: $0) }
                            ),
                            label: { $0.displayName }
                        )
                    }

                    // Proactive 5/MG guidance (#130): the strap bonds to one host at a time, so a scan
                    // here finds nothing while it's still paired in the official WHOOP app.
                    if selectedModel == .whoop5mg {
                        Text("WHOOP 5.0/MG pairs with one app at a time. If nothing's found, unpair it in the official WHOOP app and fully close that app, then Scan.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 360)
                    }

                    Button(action: { startScan() }) {
                        Label(scanning ? "Scanning…" : "Scan", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(scanning)

                    DisclosureToggle(open: $showHelp, label: String(localized: "Don't see it?"))

                    if showHelp { reassurance }

                    // WHOOP is NOOP's primary band, so onboarding leads with it — but it isn't required.
                    // Make that obvious so a non-WHOOP user doesn't feel stuck here: they can continue now
                    // and pair a heart-rate strap or import data afterwards (in Devices / Data Sources).
                    Text("No WHOOP? You can still continue. Pair a heart-rate strap (Polar, Wahoo, Coospo, Garmin HRM…) or a gym machine under Devices, or import from WHOOP, Apple Health, Oura, Fitbit, Garmin and more under Data Sources. You can do either any time.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 360)
                }
            }
        }
        .onDisappear { scanning = false }
    }

    private var statusLine: some View {
        Group {
            if live.bonded {
                StatePill("Connected", tone: .positive)
            } else if live.connected {
                StatePill("Connecting…", tone: .warning, pulsing: true)
            } else if scanning {
                StatePill("Searching", tone: .accent, pulsing: true)
            } else {
                StatePill("Ready to scan", tone: .neutral, showsDot: false)
            }
        }
    }

    private func startScan(model scanModel: WhoopModel? = nil) {
        let modelToScan = scanModel ?? selectedModel
        scanning = true
        showHelp = false
        model.scan(model: modelToScan)
        // Surface the reassurance card if we haven't bonded after a calm beat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            if !live.bonded {
                scanning = false
                withAnimation(StrandMotion.gentle) { showHelp = true }
            }
        }
    }

    private func restartScan(for newModel: WhoopModel) {
        selectedModelRaw = newModel.rawValue
        guard !live.bonded else { return }
        model.disconnect()
        startScan(model: newModel)
    }

    // The calm, never-alarmist "can't find it" card.
    private var reassurance: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(StrandPalette.statusWarning)
                    Text("Don't see it? That's normal.")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }

                Text("WHOOP straps don't appear in your \(Platform.deviceNoun)'s Bluetooth settings. They advertise on a custom profile that only apps like Zoop can find, so there's nothing to pair there, and you shouldn't try.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(StrandPalette.hairline)

                VStack(alignment: .leading, spacing: 10) {
                    Checkline(text: String(localized: "It's charged and worn. The sensor needs skin contact to wake."))
                    Checkline(text: String(localized: "It isn't held by the WHOOP phone app. Only one host at a time: close the app or turn off its Bluetooth."))
                    Checkline(text: String(localized: "It's within about a metre of \(Platform.deviceNounPhrase)."))
                }

                Button(action: retry) {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: 480)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func retry() {
        withAnimation(StrandMotion.gentle) { showHelp = false }
        startScan()
    }
}

// MARK: - Step 6 · Bonding celebration

private struct BondedStep: View {
    @EnvironmentObject private var live: LiveState
    @State private var bloom = false
    var body: some View {
        StepShell {
            VStack(spacing: 26) {
                Spacer()
                ZStack {
                    // The Home score ring fills all the way round: a taste of the dashboard to come.
                    SquircleRing(fraction: bloom ? 1 : 0, tint: StrandPalette.accent, lineWidth: 10)
                        .frame(width: 180, height: 180)
                    Image(systemName: "checkmark")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .scaleEffect(bloom ? 1 : 0.4)
                        .opacity(bloom ? 1 : 0)
                }
                .frame(height: 210)

                VStack(spacing: 8) {
                    Text("You're connected.")
                        .font(StrandFont.title1)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(batteryLine)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .opacity(bloom ? 1 : 0)
                Spacer()
            }
        }
        .onAppear { withAnimation(.easeOut(duration: 0.9)) { bloom = true } }
    }

    private var batteryLine: String {
        if let pct = live.batteryPct {
            return String(localized: "Your strap is bonded · \(Int(pct))% battery.")
        }
        return String(localized: "Your strap is bonded and ready to stream.")
    }
}

// MARK: - Step 8 · Import (optional)

private struct ImportStep: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingImporter = false
    @State private var importTarget: ImportTarget = .whoop

    var body: some View {
        StepShell(title: String(localized: "Bring your history"),
                  subtitle: String(localized: "Optional: import now, or continue and return to Data Sources later.")) {
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(StrandPalette.accentMuted.opacity(0.45))
                        .frame(width: 96, height: 96)
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(StrandPalette.icon(StrandPalette.accent))
                }

                InfoCard(
                    icon: "clock.arrow.circlepath",
                    tint: StrandPalette.accent,
                    title: String(localized: "Import past data"),
                    message: String(localized: "A WHOOP export backfills recovery, strain, sleep and workouts. Apple Health can add HR, HRV, sleep, SpO₂, steps, workouts and weight.")
                )

                StrandCard {
                    VStack(spacing: 10) {
                        ImportActionButton(
                            title: model.isImporting(.whoop) ? String(localized: "Importing…") : String(localized: "Import WHOOP export"),
                            systemImage: "tray.and.arrow.down",
                            disabled: model.hasActiveImport
                        ) {
                            presentImporter(.whoop)
                        }
                        ImportActionButton(
                            title: model.isImporting(.appleHealth) ? String(localized: "Working…") : String(localized: "Import Apple Health export"),
                            systemImage: "heart.fill",
                            disabled: model.hasActiveImport
                        ) {
                            presentImporter(.appleHealth)
                        }
                    }
                }
                .frame(maxWidth: 480)

                if model.hasActiveImport {
                    ProgressView()
                        .controlSize(.small)
                        .tint(StrandPalette.accent)
                }

                // Show the summary for the source the user last imported, styled off the typed
                // failure flag (not a substring match) so real errors read as warnings.
                if let summary = lastSummary {
                    Text(summary)
                        .font(StrandFont.subhead)
                        .foregroundStyle(model.importFailed(importKind) ? StrandPalette.statusWarning : StrandPalette.statusPositive)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: importTarget.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result, for: importTarget)
        }
    }

    /// The AppModel source kind matching the last-chosen import target.
    private var importKind: DataSourceImportKind {
        switch importTarget {
        case .whoop: return .whoop
        case .appleHealth: return .appleHealth
        }
    }

    /// The summary for the source the user last imported in this step.
    private var lastSummary: String? {
        switch importTarget {
        case .whoop: return model.whoopImportSummary
        case .appleHealth: return model.appleHealthImportSummary
        }
    }

    private func presentImporter(_ target: ImportTarget) {
        importTarget = target
        showingImporter = true
    }

    private func handleImportResult(_ result: Result<[URL], Error>, for target: ImportTarget) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        switch target {
        case .whoop:
            model.importWhoop(url: url)
        case .appleHealth:
            model.importAppleHealth(url: url)
        }
    }

    private enum ImportTarget {
        case whoop
        case appleHealth

        var allowedContentTypes: [UTType] {
            // See DataSourcesView: `.folder` is a macOS-only affordance (pick an unzipped export
            // directory). On iOS it greys out the .zip in the Files picker (issue #179), so iOS
            // offers only the concrete file types.
            switch self {
            case .whoop:
                #if os(macOS)
                return [.zip, .folder]
                #else
                return [.zip]
                #endif
            case .appleHealth:
                #if os(macOS)
                return [.zip, .xml, .folder]
                #else
                return [.zip, .xml]
                #endif
            }
        }
    }
}

// MARK: - Step 9 · Notifications (wrist alerts priming)

private struct NotificationsStep: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Low Power Mode / "Reduce motion in NOOP" pose these looping glows still too. Onboarding is
    /// first-run only, but a `repeatForever` is a `repeatForever` wherever it lives.
    @ObservedObject private var motion = ZoopMotionState.shared
    private var poseStill: Bool { motion.poseStill(reduceMotion) }
    var body: some View {
        StepShell(title: String(localized: "Notifications"),
                  subtitle: String(localized: "Alerts can vibrate on your strap instead of your \(Platform.deviceNoun).")) {
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .stroke(StrandPalette.accent.opacity(0.25), lineWidth: 2)
                        .frame(width: 120, height: 120)
                        .scaleEffect(pulse ? 1.2 : 0.9)
                        .opacity(pulse ? 0 : 0.8)
                    Circle()
                        .fill(StrandPalette.accentMuted.opacity(0.5))
                        .frame(width: 86, height: 86)
                    Image(systemName: "bell.badge")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(StrandPalette.icon(StrandPalette.accent))
                }
                .frame(height: 130)

                #if os(iOS)
                // iOS gives an app no way to observe *other* apps' notifications, and the per-app picker
                // behind it is NSWorkspace-based (macOS-only). So drop the cross-app relay claim here and
                // keep only what iOS genuinely does: NOOP's own strain nudges + smart alarm buzz the strap
                // directly over BLE.
                InfoCard(
                    icon: "applewatch.radiowaves.left.and.right",
                    tint: StrandPalette.statusPositive,
                    title: String(localized: "On your wrist"),
                    message: String(localized: "Strain alerts and the smart alarm vibrate on your strap.")
                )

                VStack(spacing: 12) {
                    Checkline(text: String(localized: "Strain nudges and your smart alarm tap your wrist the moment they fire."))
                    Checkline(text: String(localized: "It all stays on your strap and \(Platform.deviceNounPhrase): no account, no cloud."))
                }
                .frame(maxWidth: 460)
                #else
                InfoCard(
                    icon: "applewatch.radiowaves.left.and.right",
                    tint: StrandPalette.statusPositive,
                    title: String(localized: "On your wrist"),
                    message: String(localized: "When the \(Platform.deviceNoun) apps you choose send a notification, Zoop taps your strap: Slack, Calendar, Messages, whatever matters. Everything stays on \(Platform.deviceNounPhrase).")
                )

                VStack(spacing: 12) {
                    Checkline(text: String(localized: "Pick which apps reach your wrist in Settings → Notifications."))
                    Checkline(text: String(localized: "Strain nudges and your smart alarm tap your wrist the same way."))
                }
                .frame(maxWidth: 460)
                #endif
            }
        }
        .onAppear { if !poseStill { withAnimation(StrandMotion.breathe) { pulse = true } } }
    }
}

// MARK: - Step 10 · Done

private struct DoneStep: View {
    @State private var appear = false
    var body: some View {
        StepShell {
            VStack(spacing: 22) {
                Spacer()
                ZStack {
                    SquircleRing(fraction: appear ? 1 : 0, tint: StrandPalette.accent, lineWidth: 8)
                        .frame(width: 128, height: 128)
                    Image(systemName: "checkmark")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .scaleEffect(appear ? 1 : 0.6)
                        .opacity(appear ? 1 : 0)
                }
                .frame(height: 140)

                VStack(spacing: 10) {
                    Text("You're all set")
                        .font(StrandFont.title1)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Live heart rate works now. Your first scores appear after a night of wear.")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .opacity(appear ? 1 : 0)
                Spacer()
            }
        }
        .onAppear { withAnimation(.easeOut(duration: 0.9)) { appear = true } }
    }
}

// MARK: - Step shell (shared layout for each page)

/// Lets a brand-new user pick the app's look up front (and learn it's changeable) — the same
/// System / Light / Dark setting that lives in Settings → Appearance. Selecting re-themes the whole
/// app live (the shared `@AppStorage(AppearanceMode.storageKey)` drives `preferredColorScheme`), so
/// the wizard itself IS the preview.
private struct AppearanceStep: View {
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    private var binding: Binding<AppearanceMode> {
        Binding(get: { AppearanceMode(rawValue: appearanceRaw) ?? .system },
                set: { appearanceRaw = $0.rawValue })
    }
    var body: some View {
        StepShell(title: String(localized: "Make it yours"),
                  subtitle: String(localized: "Choose how Zoop looks. The whole app updates as you tap. You can change this any time in Settings → Appearance.")) {
            VStack(spacing: 28) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(StrandPalette.icon(StrandPalette.accent))
                    .frame(height: 96)
                SegmentedPillControl(AppearanceMode.allCases, selection: binding) { $0.label }
                    .frame(maxWidth: 320)
                Text("System follows your \(Platform.deviceNoun)'s light or dark setting.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 460)
        }
    }
}

private struct StepShell<Content: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 20) {
                if title != nil || subtitle != nil {
                    VStack(spacing: 8) {
                        if let title {
                            Text(title)
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .multilineTextAlignment(.center)
                        }
                        if let subtitle {
                            Text(subtitle)
                                .font(StrandFont.body)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.top, 8)
                }
                content()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
        #if os(iOS)
        // #697/#horizontal-swipe parity, see ScreenScaffold. First-run wizard, every step routes
        // through this one shell, so a single fix here covers the whole onboarding flow.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
    }
}

// MARK: - Radar sweep

private struct RadarSweep: View {
    var active: Bool
    var bonded: Bool
    @State private var angle: Double = 0
    @State private var ping = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Low Power Mode / "Reduce motion in NOOP" pose these looping glows still too. Onboarding is
    /// first-run only, but a `repeatForever` is a `repeatForever` wherever it lives.
    @ObservedObject private var motion = ZoopMotionState.shared
    private var poseStill: Bool { motion.poseStill(reduceMotion) }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                // Concentric rings.
                ForEach(1...3, id: \.self) { i in
                    Circle()
                        .stroke(StrandPalette.hairline.opacity(0.7), lineWidth: 1)
                        .frame(width: size * Double(i) / 3, height: size * Double(i) / 3)
                }
                // Cross hairs.
                Path { p in
                    p.move(to: CGPoint(x: size / 2, y: 0)); p.addLine(to: CGPoint(x: size / 2, y: size))
                    p.move(to: CGPoint(x: 0, y: size / 2)); p.addLine(to: CGPoint(x: size, y: size / 2))
                }
                .stroke(StrandPalette.hairline.opacity(0.5), lineWidth: 1)

                // The sweeping wedge.
                if active {
                    sweepWedge(size: size)
                        .rotationEffect(.degrees(angle))
                }

                // Center node — accent while searching, mint when bonded.
                Circle()
                    .fill(bonded ? StrandPalette.recovery100 : StrandPalette.accent)
                    .frame(width: 14, height: 14)
                    .shadow(color: (bonded ? StrandPalette.recovery100 : StrandPalette.accent).opacity(0.8),
                            radius: ping ? 10 : 4)

                // A discovered "blip" once bonded.
                if bonded {
                    Circle()
                        .fill(StrandPalette.statusPositive)
                        .frame(width: 12, height: 12)
                        .shadow(color: StrandPalette.statusPositive.opacity(0.9), radius: 8)
                        .position(x: size * 0.70, y: size * 0.36)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: size, height: size)
        }
        .onAppear {
            if active { startSweep() }
            ping = true
        }
        .onChangeCompat(of: active) { isActive in
            if isActive { startSweep() }
        }
        .animation(StrandMotion.breathe(reduced: poseStill), value: ping)
    }

    private func sweepWedge(size: CGFloat) -> some View {
        let radius = size / 2
        return AngularGradient(
            gradient: Gradient(colors: [StrandPalette.accent.opacity(0.0),
                                        StrandPalette.accent.opacity(0.45)]),
            center: .center,
            startAngle: .degrees(-50),
            endAngle: .degrees(0)
        )
        .mask(
            Path { p in
                let c = CGPoint(x: radius, y: radius)
                p.move(to: c)
                p.addArc(center: c, radius: radius,
                         startAngle: .degrees(-50), endAngle: .degrees(0), clockwise: false)
                p.closeSubpath()
            }
        )
        .frame(width: size, height: size)
        .blendMode(.plusLighter)
    }

    private func startSweep() {
        // Reduce Motion: keep the wedge still (the static rings/crosshairs/blip
        // still convey "searching" / "found") instead of spinning forever.
        guard !poseStill else { return }
        angle = 0
        withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
            angle = 360
        }
    }
}

// MARK: - The bottom "thread" progress

private struct ThreadProgress: View {
    var progress: Double           // 0...1
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(StrandPalette.surfaceRaised)
                Capsule()
                    .fill(StrandPalette.accent)
                    .frame(width: max(6, geo.size.width * progress))
                    .animation(StrandMotion.gentle, value: progress)
            }
        }
    }
}

// MARK: - Reusable pieces

private struct InfoCard: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String
    var body: some View {
        OnboardingRow(icon: icon, tint: tint, title: title, message: message)
            .frame(maxWidth: 480)
    }
}

private struct Checkline: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(StrandPalette.statusPositive)
                .padding(.top, 1)
            Text(text)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct FieldRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).strandOverline()
            Spacer()
            Text(value)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }
}

private struct DisclosureToggle: View {
    @Binding var open: Bool
    let label: String
    var body: some View {
        Button {
            withAnimation(StrandMotion.gentle) { open.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.up" : "chevron.down")
                Text(label)
            }
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.accent)
        }
        .buttonStyle(.plain)
    }
}

private struct ImportActionButton: View {
    let title: String
    let systemImage: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18)
                Text(title)
                    .font(StrandFont.subhead.weight(.semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
    }
}

// MARK: - Button styles

private struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 17, weight: .semibold))
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 14, weight: .semibold))
                }
            }
        }
        .buttonStyle(PrimaryButtonStyle())
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // The concept's primary control: a white pill with dark text.
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .foregroundStyle(StrandPalette.surfaceBase)
            .padding(.horizontal, 20)
            .background(
                Capsule()
                    .fill(StrandPalette.textPrimary.opacity(configuration.isPressed ? 0.85 : 1))
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(StrandMotion.interactive, value: configuration.isPressed)
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StrandFont.subhead.weight(.semibold))
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
            .background(ZoopPanelSurface(cornerRadius: 18, surfaceOpacity: configuration.isPressed ? 0.8 : 1))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(StrandMotion.interactive, value: configuration.isPressed)
    }
}

// MARK: - Preview

#if DEBUG
private struct OnboardingPreview: View {
    @StateObject private var model = AppModel()
    var body: some View {
        OnboardingWizard(onFinished: {})
            .environmentObject(model)
            .environmentObject(model.live)
            .environmentObject(model.profile)
            .frame(width: 1100, height: 780)
    }
}

#Preview("Onboarding") { OnboardingPreview() }
#endif
