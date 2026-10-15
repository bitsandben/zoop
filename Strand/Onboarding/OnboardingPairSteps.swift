import SwiftUI
import CoreBluetooth
import StrandDesign

// MARK: - Steps 4–5: Bluetooth and pairing
//
// BLE safety: the scan code below is the pre-2.0 onboarding `ScanStep` moved as-is: the same
// `model.scan(model:)` / `model.disconnect()` calls, in the same order, under the same conditions,
// with the same 12 s reassurance timer. Bond handling stays entirely in BLEManager; this file only
// observes `LiveState`. Any change to what is called here needs strap validation (4.0 and 5.0/MG).

/// Survives the pair step being torn down when the user goes back to the device choice, so a strap
/// change after a scan can restart that scan for the new family.
struct OnboardingPairingState {
    private(set) var scanRequested = false
    var rescanPending = false

    mutating func noteScanStarted() { scanRequested = true }

    /// Records the chosen family in the shared `selectedWhoopModel` key. If a scan already ran, the
    /// pair step restarts it on appear (the old in-scan model switch did that immediately).
    mutating func choose(_ model: WhoopModel) {
        let key = "selectedWhoopModel"
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(model.rawValue, forKey: key)
        if scanRequested && previous != model.rawValue { rescanPending = true }
    }
}

struct OnboardingBluetoothStep: View {
    @State private var authorization = CBManager.authorization
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    var body: some View {
        OnboardingPage(title: String(localized: "zoop.onboarding.bluetooth.title"),
                       subtitle: String(localized: "zoop.onboarding.bluetooth.subtitle")) {
            VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) {
                ListCard {
                    OnboardingInfoRow(icon: "dot.radiowaves.left.and.right",
                                      title: String(localized: "zoop.onboarding.bluetooth.direct.title"),
                                      message: String(localized: "zoop.onboarding.bluetooth.direct.body"))
                        .listCardRow(isFirst: true)
                    OnboardingInfoRow(icon: "lock.shield", tint: StrandPalette.statusPositive,
                                      title: String(localized: "zoop.onboarding.bluetooth.local.title"),
                                      message: String(localized: "zoop.onboarding.bluetooth.local.body"))
                        .listCardRow()
                }
                status
            }
        }
        // The permission can change in Settings while we are in the background.
        .onAppear { authorization = CBManager.authorization }
        #if os(iOS)
        .onChangeCompat(of: scenePhase) { if $0 == .active { authorization = CBManager.authorization } }
        #endif
    }

    @ViewBuilder private var status: some View {
        switch authorization {
        case .allowedAlways:
            OnboardingStatusLine(text: String(localized: "zoop.onboarding.bluetooth.allowed"),
                                 tint: StrandPalette.statusPositive)
        case .denied, .restricted:
            VStack(alignment: .leading, spacing: ZoopSpacing.m) {
                OnboardingStatusLine(text: String(localized: "zoop.onboarding.bluetooth.denied"),
                                     tint: StrandPalette.statusWarning)
                #if os(iOS)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link(destination: url) {
                        Text("zoop.onboarding.bluetooth.openSettings")
                    }
                    .buttonStyle(ZoopButtonStyle(.secondary, fullWidth: true))
                }
                #endif
            }
        default:
            OnboardingStatusLine(text: String(localized: "zoop.onboarding.bluetooth.ask"),
                                 tint: StrandPalette.textTertiary)
        }
    }
}

struct OnboardingPairStep: View {
    @Binding var pairing: OnboardingPairingState
    let changeDevice: () -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    @State private var scanning = false
    @State private var showHelp = false

    /// Which strap to look for: the key every scan entry point shares (Live, Devices, menu bar).
    @AppStorage("selectedWhoopModel") private var selectedModelRaw = WhoopModel.whoop4.rawValue
    private var selectedModel: WhoopModel { WhoopModel(rawValue: selectedModelRaw) ?? .whoop4 }

    var body: some View {
        OnboardingPage(title: String(localized: "zoop.onboarding.pair.title \(selectedModel.displayName)"),
                       subtitle: live.bonded ? nil : String(localized: "zoop.onboarding.pair.subtitle")) {
            VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) {
                OnboardingRadar(active: scanning && !live.bonded, bonded: live.bonded)
                    .frame(width: 168, height: 168)
                    .frame(maxWidth: .infinity)
                statusLine.frame(maxWidth: .infinity)
                if live.bonded { bondedFacts } else { preparation }
            }
        }
        .onAppear {
            guard pairing.rescanPending else { return }
            pairing.rescanPending = false
            restartScan(for: selectedModel)
        }
        .onDisappear { scanning = false }
    }

    private var statusLine: some View {
        Group {
            if live.bonded {
                OnboardingStatusLine(text: String(localized: "zoop.onboarding.pair.status.bonded"),
                                     tint: StrandPalette.statusPositive)
            } else if live.connected {
                OnboardingStatusLine(text: String(localized: "zoop.onboarding.pair.status.connecting"),
                                     tint: StrandPalette.statusWarning)
            } else if scanning {
                OnboardingStatusLine(text: String(localized: "zoop.onboarding.pair.status.searching"),
                                     tint: StrandPalette.accent)
            } else {
                OnboardingStatusLine(text: String(localized: "zoop.onboarding.pair.status.ready"),
                                     tint: StrandPalette.textTertiary)
            }
        }
    }

    @ViewBuilder private var preparation: some View {
        WhoopSingleConnectionNote()
        ListCard {
            ForEach(Array(WhoopPairingGuide.prepSteps(for: selectedModel).enumerated()), id: \.offset) { i, line in
                HStack(alignment: .top, spacing: ZoopSpacing.m) {
                    Text(verbatim: "\(i + 1)")
                        .font(ZoopType.headline.monospacedDigit())
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 20, alignment: .leading)
                    Text(line)
                        .font(ZoopType.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .listCardRow(isFirst: i == 0)
            }
        }
        Button(action: { startScan() }) {
            Label(scanning ? String(localized: "zoop.onboarding.pair.scanning")
                           : String(localized: "zoop.onboarding.pair.scan"),
                  systemImage: "dot.radiowaves.left.and.right")
        }
        .buttonStyle(ZoopButtonStyle(.secondary, fullWidth: true))
        .disabled(scanning)
        if showHelp { reassurance }
        Button("zoop.onboarding.pair.changeDevice", action: changeDevice)
            .buttonStyle(ZoopButtonStyle(.tertiary))
            .frame(maxWidth: .infinity)
    }

    private var bondedFacts: some View {
        ListCard {
            OnboardingFactRow(label: String(localized: "zoop.onboarding.pair.fact.strap"),
                              value: live.advertisingName ?? selectedModel.displayName)
                .listCardRow(isFirst: true)
            if let pct = live.batteryPct {
                OnboardingFactRow(label: String(localized: "zoop.onboarding.pair.fact.battery"),
                                  value: (pct / 100).formatted(.percent.precision(.fractionLength(0))))
                    .listCardRow()
            }
            if let firmware = live.strapFirmware {
                OnboardingFactRow(label: String(localized: "zoop.onboarding.pair.fact.firmware"), value: firmware)
                    .listCardRow()
            }
        }
    }

    /// The calm "can't find it" card, shown after a scan stays empty for 12 s.
    private var reassurance: some View {
        ContentCard(LocalizedStringKey("zoop.onboarding.pair.help.title")) {
            VStack(alignment: .leading, spacing: ZoopSpacing.m) {
                Text("WHOOP straps don't appear in your \(Platform.deviceNoun)'s Bluetooth settings. They advertise on a custom profile that only apps like Zoop can find, so there's nothing to pair there, and you shouldn't try.")
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("It's charged and worn. The sensor needs skin contact to wake.")
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: retry) {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(ZoopButtonStyle(.secondary))
            }
        }
        .transition(.opacity)
    }

    // MARK: Scan (unchanged behaviour, see the file header)

    private func startScan(model scanModel: WhoopModel? = nil) {
        let modelToScan = scanModel ?? selectedModel
        scanning = true
        showHelp = false
        pairing.noteScanStarted()
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

    private func retry() {
        withAnimation(StrandMotion.gentle) { showHelp = false }
        startScan()
    }
}
