import SwiftUI
import StrandDesign

/// Strap: connection state and the controls that change how the strap runs (power, alarms, capture).
struct SettingsStrapPage: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    /// Holds the dense R-R stream armed so overnight HRV has more beats to work with, at a battery cost.
    @AppStorage(PuffinExperiment.keepRealtimeForDataKey) private var continuousHrvEnabled = false
    /// #1008: the default MUST match `PuffinExperiment.continuousHrvOvernightOnlyEnabled`. Both read one
    /// key by different routes, and a mismatch shows the switch off while capture is overnight-only.
    @AppStorage(PuffinExperiment.continuousHrvOvernightOnlyKey) private var continuousHrvOvernightOnly = true
    #if os(iOS)
    @AppStorage(ScreenIdle.strapSyncKeepAwakeKey) private var syncKeepScreenOn = false
    #endif

    var body: some View {
        SettingsPageScaffold(title: "Strap") {
            connectionGroup
            SettingsGroup {
                SettingsLinkRow(label: "Power saving", icon: "battery.25", isFirst: true) { PowerSavingView() }
                #if os(iOS)
                SettingsLinkRow(label: "Alarms", icon: "alarm.fill") { SleepPlannerHost() }
                SettingsToggleRow(label: "Keep screen on while syncing", isOn: $syncKeepScreenOn,
                                  note: "zoop.settings.strap.keepAwakeNote")
                #endif
            }
            captureGroup
        }
    }

    // MARK: Connection

    private var connectionGroup: some View {
        SettingsGroup(footer: Text(verbatim: statusDetail)) {
            SettingsRow(label: "Connection", isFirst: true) {
                HStack(spacing: ZoopSpacing.s) {
                    Circle().fill(statusColor).frame(width: 8, height: 8).accessibilityHidden(true)
                    // Shares LiveState's label with the sidebar footer so the two never drift (#266).
                    Text(verbatim: live.connectionStatusLabel)
                        .font(ZoopType.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            if let pct = live.batteryPct {
                SettingsRow(label: "Battery") {
                    Text(live.charging == true
                         ? "zoop.settings.strap.batteryCharging \(Int(pct.rounded()))"
                         : "zoop.settings.strap.battery \(Int(pct.rounded()))")
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(pct <= 15 ? StrandPalette.statusCritical : StrandPalette.textSecondary)
                }
            }
            HStack(spacing: ZoopSpacing.m) {
                ZoopButton("Re-scan", systemImage: "arrow.clockwise", kind: .primary) { model.scan() }
                ZoopButton("Disconnect", systemImage: "xmark.circle", kind: .secondary) { model.disconnect() }
                    .disabled(!live.connected && !live.bonded)
            }
            .listCardRow()
        }
    }

    private var statusColor: Color {
        if live.connectionStatusIsActive { return StrandPalette.statusPositive }
        if live.connectionStatusIsIdle { return StrandPalette.statusWarning }
        return StrandPalette.statusCritical
    }

    /// `encryptedBond`, not `bonded`: a live-HR-only link is not "paired" in the sense the buzz, alarm
    /// and sync controls need. Once the #1635 handshake suppression latches nothing is "finishing" any
    /// more, which is why the bonded-and-connected arm precedes the handshake line.
    private var statusDetail: String {
        if live.encryptedBond && live.connected {
            return String(localized: "zoop.settings.strap.paired")
        }
        // An actionable hint outranks the generic arms: it names the one step that restores the handshake.
        if live.connected, let hint = live.pairingHint { return hint }
        if live.bonded && live.connected { return String(localized: "zoop.settings.strap.liveOnly") }
        if live.connected { return String(localized: "Connected. Finishing the secure pairing handshake…") }
        if live.bonded { return String(localized: "Previously paired but not currently connected. Re-scan to reconnect.") }
        return String(localized: "No strap connected. Put your WHOOP nearby and tap Re-scan to pair.")
    }

    // MARK: Capture

    private var captureGroup: some View {
        SettingsGroup(title: "zoop.settings.group.capture") {
            SettingsToggleRow(label: "Continuous HRV capture", isOn: $continuousHrvEnabled,
                              note: "zoop.settings.strap.continuousHrvNote", isFirst: true)
                .onChangeCompat(of: continuousHrvEnabled) { model.ble.setKeepRealtimeForData($0) }
            // #927: window-gate the stream to quiet hours, roughly halving its battery cost.
            if continuousHrvEnabled {
                SettingsToggleRow(label: "Overnight only", isOn: $continuousHrvOvernightOnly,
                                  note: "zoop.settings.strap.overnightNote")
                    .onChangeCompat(of: continuousHrvOvernightOnly) { _ in
                        model.ble.setKeepRealtimeForData(PuffinExperiment.keepRealtimeForDataEnabled)
                    }
            }
        }
    }
}
