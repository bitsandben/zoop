import SwiftUI
import StrandDesign

/// Data: the one home for backup, export, sources and storage. The More tab no longer repeats these
/// rows (design audit X11: Backup sat in two places).
struct SettingsDataPage: View {
    @EnvironmentObject private var model: AppModel

    @State private var busy = false
    @State private var notice: SettingsNotice?
    /// #1807: a restore refused only for size is recoverable, so it gets a two-button confirm.
    @State private var oversizeRestoreMessage: String?

    var body: some View {
        SettingsPageScaffold(title: "Data") {
            backupGroup
            SettingsGroup(title: "zoop.settings.group.sources") {
                SettingsLinkRow(label: "Apple Health", icon: "heart.fill", isFirst: true) { AppleHealthView() }
                SettingsLinkRow(label: "Data Sources", icon: "point.3.connected.trianglepath.dotted") { DataSourcesView() }
                SettingsLinkRow(label: "Mi Band", icon: "applewatch.side.right") { XiaomiBandView() }
                #if os(iOS)
                SettingsLinkRow(label: "Shortcuts Export", icon: "square.and.arrow.up") { ShortcutExportSettingsView() }
                #endif
            }
            SettingsGroup {
                SettingsLinkRow(label: "Storage", icon: "internaldrive", isFirst: true) { StorageView() }
            }
        }
        .settingsNoticeAlert($notice)
        // Title and buttons reuse catalogue strings that already carry every locale (#1807).
        .alert("Backup problem", isPresented: Binding(
            get: { oversizeRestoreMessage != nil },
            set: { if !$0 { oversizeRestoreMessage = nil } }
        )) {
            Button("Restore") { runImport(allowOversize: true) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(oversizeRestoreMessage ?? "")
        }
    }

    // #644: a .zoopbak is a plain ZIP, so the footer says so next to Export rather than letting people
    // assume the file is protected once it leaves the device.
    private var backupGroup: some View {
        SettingsGroup(title: "Backup & restore", footer: Text("zoop.settings.data.backupNote")) {
            SettingsActionRow(label: "Export…", icon: "square.and.arrow.up", isFirst: true) { runExport() }
                .disabled(busy)
            SettingsActionRow(label: "Import…", icon: "square.and.arrow.down") { runImport() }
                .disabled(busy)
            SettingsActionRow(label: "Export CSV…", icon: "tablecells") { runCsvExport() }
                .disabled(busy)
            SettingsLinkRow(label: "Backup & Sync", icon: "externaldrive.fill.badge.icloud") { BackupSyncView() }
            if busy {
                HStack(spacing: ZoopSpacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Working…").font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                .listCardRow()
            }
        }
    }

    // MARK: Actions

    private func runExport() {
        busy = true
        Task {
            let result = await DataBackup.runExport(checkpoint: { await model.repo.checkpointForBackup() })
            handle(result)
        }
    }

    private func runImport(allowOversize: Bool = false) {
        busy = true
        Task { handle(await DataBackup.runImport(allowOversize: allowOversize)) }
    }

    private func runCsvExport() {
        busy = true
        Task {
            let result = await CsvExport.run(repo: model.repo)
            busy = false
            switch result {
            case .cancelled:
                return
            case .exported(let url):
                notice = SettingsNotice(
                    title: String(localized: "CSV exported"),
                    message: String(localized: "Saved to \(url.lastPathComponent). The zip re-imports into Zoop (Data Sources → WHOOP Export) on any Mac, iPhone, or Android device."))
            case .failure(let message):
                notice = SettingsNotice(title: String(localized: "Export problem"), message: message)
            }
        }
    }

    @MainActor
    private func handle(_ result: DataBackup.BackupResult) {
        busy = false
        switch result {
        case .cancelled:
            return
        case .exported(let url):
            notice = SettingsNotice(
                title: String(localized: "Backup exported"),
                message: String(localized: "Saved to \(url.lastPathComponent). Copy this file to your other \(Platform.deviceNoun) and use Import there to restore everything."))
        case .exportedOversize(let url, let bytes, let limit):
            // #1807: the file is complete and worth keeping; say so now rather than at restore time,
            // when the original may already be gone.
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            let cap = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
            notice = SettingsNotice(
                title: String(localized: "Backup exported"),
                message: String(localized: "Saved to \(url.lastPathComponent). Your database is \(size), over the \(cap) Zoop restores without asking — the backup is complete and valid, and restoring it will ask you to confirm once."))
        case .restoreTooLarge(let name, let limit):
            let cap = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
            oversizeRestoreMessage = String(localized: "\(name) is larger than the \(cap) Zoop restores without asking. That limit guards against a malicious archive expanding to fill this \(Platform.deviceNoun) — a backup you exported yourself is not that. Restoring it needs the space the database will take. You'll be asked to choose the file again.")
        case .imported:
            notice = SettingsNotice(
                title: String(localized: "Backup imported"),
                message: String(localized: "Your data has been restored. Quit and reopen Zoop for it to take effect."))
        case .failure(let message):
            notice = SettingsNotice(title: String(localized: "Backup problem"), message: message)
        }
    }
}
