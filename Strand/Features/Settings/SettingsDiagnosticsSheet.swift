#if os(iOS)
import SwiftUI
import StrandDesign

/// A read-only environment dump for bug reports: device, iOS and build, Data Protection (#222),
/// background refresh, Low Power Mode, sideload and certificate expiry, with one-tap Copy.
struct SettingsDiagnosticsSheet: View {
    let onClose: () -> Void

    /// Captured once at presentation; a snapshot, not a live monitor.
    private let lines: [String] = IOSDiagnostics.capture().summaryLines()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZoopSpacing.s) {
                    if lines.isEmpty {
                        Text("No iOS diagnostics available.")
                            .font(ZoopType.body)
                            .foregroundStyle(StrandPalette.textTertiary)
                    } else {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line)
                                .font(StrandFont.mono(12))
                                .foregroundStyle(StrandPalette.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(ZoopSpacing.l)
                .background(StrandPalette.surfaceInset,
                            in: RoundedRectangle(cornerRadius: ZoopRadius.tile, style: .continuous))
                .padding(ZoopSpacing.gutter)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Copy") { PlatformPasteboard.copy(lines.joined(separator: "\n")) }
                        .disabled(lines.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onClose).foregroundStyle(StrandPalette.accent)
                }
            }
        }
    }
}
#endif
