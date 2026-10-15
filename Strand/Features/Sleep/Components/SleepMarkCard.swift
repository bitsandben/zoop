import SwiftUI
import StrandDesign
import WhoopStore

/// Tap-to-log "going to sleep" / "I'm awake" marks. Logging only: a mark is written to the metric
/// series and the strap log and never changes the detected night. Hosted by Today on macOS too.
struct SleepMarkCard: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var live: LiveState

    /// The most recent sleep-mark the user tapped, shown as a transient confirmation line under the
    /// two buttons. Drives the SwiftUI haptic landing too. LOGGING-ONLY: a mark never feeds the sleep
    /// detector — it's persisted to the metric series + strap log.
    @State private var lastMark: SleepMark?

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopMetrics.gap) {
            SectionHeader("Sleep marks", overline: "Tap to log")
            ZoopCard(tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: ZoopMetrics.cardInnerSpacing) {
                    Text("Tap when you're heading to bed or when you wake. Each tap is logged with the time. It doesn't change tonight's detected sleep.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: ZoopMetrics.gap) {
                        // Routed through the unified ZoopButton system so the two marks sit identically
                        // (sentence-case label, leading icon at 8pt, controlHeight=48, no glow).
                        ZoopButton("Going to sleep", systemImage: "moon.zzz.fill",
                                   kind: .secondary, fullWidth: true) { logMark(.bedtime) }
                            .accessibilityLabel("Log going to sleep")

                        ZoopButton("I'm awake", systemImage: "sun.max.fill",
                                   kind: .secondary, fullWidth: true) { logMark(.wake) }
                            .accessibilityLabel("Log waking up")
                    }
                    if let lastMark {
                        Text(lastMark.confirmation)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.icon(StrandPalette.restColor))
                            .transition(.opacity)
                            .accessibilityLabel(lastMark.confirmation)
                    }
                }
            }
        }
        // A success haptic lands when a new mark is captured (value-driven, not per-tap), matching the
        // app's sparse tactile vocabulary. No-op on macOS.
        .strandHaptic(.success, trigger: lastMark?.tsMs ?? 0)
    }

    /// Persist + log a tapped mark. Optimistically shows the confirmation immediately, fires the
    /// haptic via `lastMark`, appends the human-readable strap-log line, then writes the metric-series
    /// row through the repo's live store handle (no new Repository API, no schema change). The write is
    /// idempotent by (deviceId, day, key).
    private func logMark(_ type: SleepMarkType) {
        let mark = SleepMark(type: type)
        withAnimation(.easeOut(duration: 0.2)) { lastMark = mark }
        // The shareable strap log is the human-readable surface that lands in a debug export.
        live.append(log: mark.logLine)
        Task {
            guard let store = await repo.storeHandle() else { return }
            try? await store.upsertMetricSeries([mark.metricPoint], deviceId: repo.deviceId)
        }
    }
}

