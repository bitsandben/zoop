import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif
import StrandDesign

/// Advanced: developer and diagnostic tools, and the algorithm experiments. Nothing here is needed for
/// everyday use; the Test Centre is the home for logs, probes and reports (#507/#509).
struct SettingsAdvancedPage: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    /// Renaming uses the WHOOP 4.0 command set, which a 5/MG does not share.
    @AppStorage("selectedWhoopModel") private var selectedWhoopModelRaw = WhoopModel.whoop4.rawValue

    @State private var rawCsvBusy = false
    @State private var lastRawCsvURL: URL?
    @State private var notice: SettingsNotice?
    @State private var showDiagnostics = false

    var body: some View {
        SettingsPageScaffold(title: "Advanced") {
            toolsGroup
            if live.connected && selectedWhoopModelRaw == WhoopModel.whoop4.rawValue {
                SettingsGroup(title: "Strap name", footer: Text("zoop.settings.advanced.renameNote")) {
                    SettingsStrapRename().listCardRow(isFirst: true)
                }
            }
            SettingsExperimentsGroup()
        }
        .settingsNoticeAlert($notice)
        #if os(iOS)
        .sheet(isPresented: $showDiagnostics) {
            SettingsDiagnosticsSheet(onClose: { showDiagnostics = false })
        }
        #endif
    }

    private var toolsGroup: some View {
        SettingsGroup(footer: Text("zoop.settings.advanced.rawCsvNote")) {
            SettingsLinkRow(label: "Test Centre", icon: "stethoscope", isFirst: true) { TestCentreView() }
            #if os(iOS)
            SettingsActionRow(label: "Diagnostics", icon: "iphone.gen3") { showDiagnostics = true }
            #endif
            SettingsActionRow(label: "Export raw sensor data (CSV)", icon: "square.and.arrow.up",
                              value: rawCsvBusy ? String(localized: "Exporting…") : nil) {
                exportRawSensorCSV()
            }
            .disabled(rawCsvBusy)
            #if os(macOS)
            if let url = lastRawCsvURL {
                SettingsActionRow(label: "Reveal in Finder", icon: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            #endif
        }
    }

    /// The last 24 h of decoded streams for the strap being worn. The id is `repo.deviceId`, which follows
    /// the registry's active strap; the hardcoded `model.deviceId` exported the wrong strap after a
    /// remove + re-add (#814). It is read on the main actor before the hop into the store.
    private func exportRawSensorCSV() {
        rawCsvBusy = true
        let strapId = model.repo.deviceId
        Task {
            let since = Date().timeIntervalSince1970 - 24 * 60 * 60
            guard let store = await model.repo.storeHandle() else {
                rawCsvBusy = false
                notice = SettingsNotice(title: String(localized: "Export failed"),
                                        message: String(localized: "Couldn't open the local store."))
                return
            }
            do {
                let url = try await store.exportRawCSV(deviceId: strapId, since: since)
                rawCsvBusy = false
                lastRawCsvURL = url
                deliver(url)
            } catch {
                rawCsvBusy = false
                notice = SettingsNotice(title: String(localized: "Export failed"), message: error.localizedDescription)
            }
        }
    }

    /// Save panel on macOS, share sheet on iOS.
    @MainActor
    private func deliver(_ url: URL) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = url.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            notice = SettingsNotice(title: String(localized: "Export failed"), message: error.localizedDescription)
        }
        #else
        FileExport.exportFile(at: url)
        #endif
    }
}

/// Renames the WHOOP 4.0's Bluetooth advertising name. The strap reboots to apply, so the new name
/// shows on the next connect.
private struct SettingsStrapRename: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            Text("Current: \(live.advertisingName ?? "—")")
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            HStack(spacing: ZoopSpacing.m) {
                TextField("New strap name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(ZoopType.body)
                    .padding(.horizontal, ZoopSpacing.m)
                    .padding(.vertical, ZoopSpacing.s)
                    .background(StrandPalette.surfaceInset,
                                in: RoundedRectangle(cornerRadius: ZoopRadius.button, style: .continuous))
                    .disableAutocorrection(true)
                ZoopButton("Rename", systemImage: "pencil", kind: .primary) { model.ble.renameStrap(draft) }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let status = live.renameStatus {
                Text(verbatim: status).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
}
