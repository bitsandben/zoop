#if DEBUG
import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// DEBUG-only: renders the stillness card from synthetic nights (`--demo-screen sleeprestless`): a solid
// night against 20 earlier ones, a sparse WHOOP 4.0-style night, and a night still learning its range.

struct SleepRestlessDemoHost: View {
    @State private var selected: SleepMetric?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) {
                ForEach(Array(Self.cards.enumerated()), id: \.offset) { _, content in
                    SleepRestlessCard(content: content) { selected = $0 }
                }
            }
            .padding(.horizontal, ZoopSpacing.gutter)
            .padding(.vertical, ZoopSpacing.m)
        }
        .sheet(item: $selected) { MetricExplainerSheet($0.readout, explanation: $0.explanation) }
    }

    private static var cards: [SleepRestlessContent] {
        [content(history: 20, moves: 14, sparse: false),
         content(history: 20, moves: 4, sparse: true),
         content(history: 3, moves: 8, sparse: false)].compactMap { $0 }
    }

    /// `history` earlier nights with 6...10 bouts, then tonight with `moves` bouts.
    private static func content(history: Int, moves: Int, sparse: Bool) -> SleepRestlessContent? {
        func night(_ bouts: Int, sparse: Bool) -> SleepRestlessness.Night? {
            var counts = [Double](repeating: 1, count: 900)
            for i in 0..<bouts { counts[30 + i * (840 / max(bouts, 1))] = 20 }
            if sparse { for i in 0..<450 { counts[i] = 0 } }
            return SleepRestlessness.analyze(epochCounts: counts, sparse: sparse)
        }
        var entries: [Int: SleepRestlessReadouts.Entry] = [:]
        let cal = Calendar.current
        for offset in 0...history {
            let date = cal.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            let bouts = offset == 0 ? moves : 6 + offset % 5
            if let n = night(bouts, sparse: offset == 0 && sparse) {
                entries[offset] = .init(day: Repository.localDayKey(date), night: n)
            }
        }
        return SleepRestlessReadouts.content(offset: 0, entries: entries)
    }
}
#endif
