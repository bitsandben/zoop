import SwiftUI
import StrandAnalytics
import StrandDesign

/// Existing routes address the screen by its old name.
typealias StressView = StressScreen

// MARK: - StressScreen (CONCEPT §3.5)
//
// "How activated is my body right now, and what can I do about it?" in a fixed order: the current level
// and today's curve, today's summary, a breathing action, the 7/30-day trend, and the patterns
// (typical day, workdays vs weekend). The screen holds no logic: `StressScreenModel` loads and resolves
// everything through `DaytimeStress` and `StressPatterns`.

struct StressScreen: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var model = StressScreenModel()

    @State private var showInfo = false
    @State private var showBreathe = false

    var body: some View {
        ScreenScaffold(title: "Stress", onRefresh: { await model.reload() }) {
            VStack(alignment: .leading, spacing: ZoopSpacing.cardGap) {
                if showsEmptyState {
                    ComingSoon(what: "No stress history yet. Import your WHOOP export in Data Sources to see it.")
                } else {
                    sections
                }
            }
        }
        .task(id: repo.refreshSeq) {
            model.attach(repo: repo)
            await model.reload()
            model.refreshAsking()
        }
        .onChangeCompat(of: repo.days) { _ in model.rebuildDaily() }
        #if os(iOS)
        // Keep the current level live while the screen is open. A rescore reads and scores the whole day,
        // so every five minutes is as often as it is worth the battery.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                await model.refreshDay()
            }
        }
        #endif
        .sheet(isPresented: $showInfo) {
            MetricExplainerSheet(model.readout(scrubbed: nil), explanation: model.explanation())
        }
        .sheet(isPresented: $showBreathe, onDismiss: { model.refreshAsking() }) {
            NavigationStack {
                BreathingView()
                    .toolbar {
                        ToolbarItem {
                            Button { showBreathe = false } label: { Text(StressStrings.breatheDone) }
                        }
                    }
            }
            #if os(macOS)
            .frame(width: 520, height: 760)
            #endif
        }
    }

    /// Nothing to show: no day carries a signal and today's read is in and empty.
    private var showsEmptyState: Bool {
        model.loaded && model.daily == nil && model.day != nil && model.points.isEmpty
    }

    private var isHigh: Bool {
        if model.day?.sustainedHigh == true { return true }
        return (model.headline.value).map { DaytimeStress.Band(level: $0) == .high } ?? false
    }

    @ViewBuilder
    private var sections: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) {
            StressNowCard(model: model) { showInfo = true }
            if model.asking {
                StressAskCard { model.answer(stressed: $0) }
            }
            if isHigh { breathe }
            if let summary = model.summary { StressTodayCard(summary: summary) }
            StressTrendCard(daily: model.daily, typical: model.typical)
            StressPatternsSection(timeOfDay: model.timeOfDay, week: model.week, loaded: model.patternsLoaded)
            if !isHigh { breathe }
            StressAdvancedCard(index: model.stressIndex, freq: model.freqHRV)
        }
    }

    private var breathe: some View {
        StressBreatheCard(isHigh: isHigh) { showBreathe = true }
    }
}
