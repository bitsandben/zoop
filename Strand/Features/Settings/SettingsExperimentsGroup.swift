import SwiftUI
import StrandDesign

/// Opt-in alternatives to the shipped algorithms. Each switch only changes how stored data is scored,
/// never what is sent to the strap.
struct SettingsExperimentsGroup: View {
    @EnvironmentObject private var model: AppModel

    /// V2 has been the default since the 44-subject cross-subject benchmark; off falls back to V1.
    @AppStorage(PuffinExperiment.experimentalSleepV2Key) private var sleepV2Enabled = true
    /// #364: folds a wake block with no locomotion and a stable posture back into light sleep. Self-gates
    /// on observed motion density (#345), so it is a no-op on a sparse night whatever this says.
    @AppStorage(PuffinExperiment.motionAwareWakeKey) private var motionAwareWakeEnabled = false
    @AppStorage(PuffinExperiment.alarmAnchoredWakeKey) private var alarmAnchoredWakeEnabled = false
    /// #1545: Banister's exponential TRIMP instead of Edwards' zones; re-scores the whole window.
    @AppStorage(PuffinExperiment.banisterEffortKey) private var banisterEffortEnabled = false
    /// #141: whole night (Zoop's default) or deep sleep only (WHOOP-style, reads lower).
    @AppStorage(UnitPrefs.hrvWindowKey) private var hrvWindowRaw = HrvWindow.whole.rawValue
    /// #103: device-conditional, unverified SpO₂ shown only when no calibrated reading exists.
    @AppStorage(PuffinExperiment.spo2CandidateDisplayKey) private var spo2CandidateEnabled = false
    /// Item 27: keeps an Oura ring in daytime-HR mode outside the learned night band.
    @AppStorage(AppModel.ouraAllDayLiveHRKey) private var ouraAllDayLiveHREnabled = false
    @AppStorage(LiveSessionPrefs.betaKey) private var liveSessionsBeta = true
    /// The same key the scan pickers write and a connecting strap rewrites (PR#195).
    @AppStorage("selectedWhoopModel") private var selectedWhoopModelRaw = WhoopModel.whoop4.rawValue

    private var isOura: Bool { model.repo.activeDeviceIsOura }
    /// The SpO₂ candidate exists on a WHOOP 5/MG and on Oura; WHOOP 4.0 has no such stream (#22).
    private var offersSpo2Candidate: Bool { selectedWhoopModelRaw == WhoopModel.whoop5mg.rawValue || isOura }

    var body: some View {
        SettingsGroup(title: "zoop.settings.group.experiments", footer: Text("zoop.settings.advanced.experimentsNote")) {
            SettingsToggleRow(label: "Sleep staging (V2)", isOn: $sleepV2Enabled,
                              note: "zoop.settings.exp.sleepV2Note", isFirst: true)
            SettingsToggleRow(label: "Motion-aware wake refinement", isOn: $motionAwareWakeEnabled,
                              note: "zoop.settings.exp.motionWakeNote")
            SettingsToggleRow(label: "Wake from alarm (experimental)", isOn: $alarmAnchoredWakeEnabled,
                              note: "zoop.settings.exp.alarmWakeNote")
            SettingsToggleRow(label: "Effort: exponential intensity scale", isOn: $banisterEffortEnabled,
                              note: "zoop.settings.exp.banisterNote")
                .onChangeCompat(of: banisterEffortEnabled) { _ in rescore() }
            SettingsMenuRow(label: "HRV window", selection: $hrvWindowRaw, note: "zoop.settings.exp.hrvWindowNote") {
                Text("Night").tag(HrvWindow.whole.rawValue)
                Text("Deep sleep").tag(HrvWindow.deep.rawValue)
            }
            // #201: the re-score re-folds the HRV baseline too, so the baseline epoch is not re-anchored.
            .onChangeCompat(of: hrvWindowRaw) { _ in rescore() }
            if offersSpo2Candidate {
                SettingsToggleRow(label: "Blood Oxygen: strap estimate (WHOOP 5/MG, Oura)",
                                  isOn: $spo2CandidateEnabled, note: "zoop.settings.exp.spo2Note")
                    .onChangeCompat(of: spo2CandidateEnabled) { _ in rescore() }
            }
            if isOura {
                SettingsToggleRow(label: "Oura ring: all-day heart rate & HRV", isOn: $ouraAllDayLiveHREnabled,
                                  note: "zoop.settings.exp.ouraAllDayNote")
            }
            SettingsToggleRow(label: "Live Sessions (beta)", isOn: $liveSessionsBeta,
                              note: "zoop.settings.exp.liveSessionsNote")
        }
    }

    /// These switches change stored scores for every day in the window, so re-score now instead of
    /// leaving the old recipe on screen until the next analysis loop.
    private func rescore() {
        Task { await model.intelligence.analyzeRecent(); await model.repo.refresh() }
    }
}
