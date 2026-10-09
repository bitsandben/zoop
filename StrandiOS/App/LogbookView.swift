import SwiftUI
import StrandDesign

/// The iOS Logbook sheet: the journal logging card on its own, one day at a time, with a pinned
/// "Save logbook" capsule. Opened from the centre quick-action menu, the Home-screen quick action and
/// the Today logbook widget (which may deep-link a specific day through `NavRouter`).
///
/// Answers are written the moment they are tapped (the same immediate writes the Insights-hosted card
/// makes), so "Save logbook" only commits a numeric field still being edited and closes the sheet.
struct LogbookView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var router: NavRouter

    /// Closes the hosting sheet.
    let onClose: () -> Void

    @State private var importedQuestions: [String] = []
    @State private var dayAnswers: [String: Bool] = [:]
    @State private var dayNumeric: [String: Double] = [:]
    /// -1 = tomorrow (log ahead), 0 = today, 1 = yesterday (late logging). Same default as Insights.
    @State private var dayOffset = 0
    @State private var loaded = false

    var body: some View {
        ScrollView {
            Group {
                if loaded {
                    JournalLogCard(importedQuestions: importedQuestions,
                                   answers: dayAnswers,
                                   numericAnswers: dayNumeric,
                                   dayOffset: $dayOffset,
                                   onChanged: { Task { await load() } })
                } else {
                    ProgressView()
                        .tint(StrandPalette.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.horizontal, ZoopMetrics.screenHPadding)
            .padding(.top, ZoopMetrics.space2)
            .padding(.bottom, ZoopMetrics.space6)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { saveBar }
        // What the answers add up to: the ranked habit effects ("What Moves You"), like WHOOP's Insights.
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink { InsightsHubView() } label: {
                    Label("Insights", systemImage: "lightbulb")
                        .labelStyle(.titleAndIcon)
                        .font(StrandFont.subhead.weight(.semibold))
                }
            }
        }
        .task {
            // Honour a day the Today logbook widget deep-linked to (#656), consumed once on arrival.
            if let day = router.pendingJournalDayOffset {
                dayOffset = day
                router.pendingJournalDayOffset = nil
            }
            await load()
        }
        .onChangeCompat(of: repo.refreshSeq) { _ in Task { await load() } }
    }

    /// The full-width white capsule pinned above the home indicator.
    private var saveBar: some View {
        Button {
            // Resigning focus lets a numeric field mid-edit commit its value before the sheet closes.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                            to: nil, from: nil, for: nil)
            onClose()
        } label: {
            Text(String(localized: "Save logbook").uppercased())
                .font(StrandFont.headline)
                .tracking(1.2)
                .foregroundStyle(StrandPalette.surfaceBase)
                .frame(maxWidth: .infinity)
                .frame(height: ZoopMetrics.controlHeight + ZoopMetrics.space1)
                .background(Capsule().fill(StrandPalette.textPrimary))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, ZoopMetrics.screenHPadding)
        .padding(.top, ZoopMetrics.space3)
        .padding(.bottom, ZoopMetrics.space2)
        .background(
            LinearGradient(colors: [StrandPalette.surfaceBase.opacity(0), StrandPalette.surfaceBase],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    /// Reads the export's question strings (so logged days join imported history) and the selected
    /// day's native answers, the same targeted reads InsightsView makes for its card.
    private func load() async {
        let imported = await repo.importedJournalEntries()
        let importedQs = NSOrderedSet(array: imported.map(\.question)).array as? [String] ?? []
        let dayKey = Repository.localDayKey(
            Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date()) ?? Date())
        let answers = await repo.nativeJournalAnswers(day: dayKey)
        let numeric = await repo.nativeJournalNumeric(day: dayKey)
        importedQuestions = importedQs
        dayAnswers = answers
        dayNumeric = numeric
        loaded = true
    }
}
