#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandDesign

// MARK: - FitnessAgeScreen (CONCEPT §3.7)
//
// Hero with the dial, what shapes the number (one anatomy row per factor), the lever, the VO₂max line,
// the weekly history and the method. `FitnessAgeModel` builds every readout; this view only lays them
// out and presents the explainer sheet.

struct FitnessAgeScreen: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var intelligence: IntelligenceEngine
    @StateObject private var model = FitnessAgeModel()
    @State private var selected: FitnessFactorItem?
    @State private var showSettings = false
    @State private var refreshing = false

    var body: some View {
        Group {
            if let latest = model.snapshot.latest, profile.age > 0 {
                ScrollView {
                    VStack(spacing: 0) {
                        FitnessAgeHero(day: latest.day, value: latest.value, chronoAge: profile.age)
                        VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) {
                            factors
                            FitnessLeverSection(advice: model.lever)
                            FitnessVO2Section(line: model.vo2Line, chronoAge: Double(profile.age),
                                              sex: profile.sex, measured: model.snapshot.vo2IsMeasured)
                            FitnessHistorySection(history: model.snapshot.history, chronoAge: Double(profile.age))
                            FitnessMethodSection()
                        }
                        .padding(.horizontal, ZoopMetrics.screenHPadding)
                        .padding(.top, ZoopSpacing.s)
                        .padding(.bottom, ZoopMetrics.tabBarClearance)
                    }
                }
                .scrollIndicators(.hidden, axes: .vertical)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .zoopPushedScreen(title: "zoop.fitnessage.title")
            } else if model.loaded {
                ScreenScaffold(title: "zoop.fitnessage.title") { notReady }
            } else {
                StrandPalette.surfaceBase.ignoresSafeArea()
            }
        }
        .sheet(item: $selected) { item in
            MetricExplainerSheet(item.readout, explanation: item.explanation)
        }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        .task(id: repo.refreshSeq) { await reload() }
    }

    private func reload() async {
        await model.reload(repo: repo, age: profile.age, sex: profile.sex)
    }

    // MARK: Factors

    private var factors: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.m) {
            FitnessSectionTitle(FitnessAgeStrings.factorsTitle)
            FitnessFactorList(items: model.factors) { selected = $0 }
            if model.missingVO2 {
                Button { showSettings = true } label: {
                    Text(FitnessAgeStrings.factorsHint)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: Not ready

    private var notReady: some View {
        let rhrDays = repo.days.suffix(7).compactMap { $0.restingHr }.count
        let readiness = FitnessAgeEngine.assessReadiness(
            hasAge: profile.age > 0, hasSex: !profile.sex.isEmpty, rhrDays: rhrDays,
            activityDays: repo.days.suffix(7).compactMap { $0.strain }.count,
            hasHeightWeight: profile.heightCm > 0 && profile.weightKg > 0, hasWaist: profile.waistCm > 0)
        return VStack(alignment: .leading, spacing: ZoopSpacing.l) {
            Text(fitnessReadyLeadCopy(rhrDays: rhrDays, hasAge: profile.age > 0, hasSex: !profile.sex.isEmpty))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(readiness.items, id: \.key) { item in
                HStack(spacing: ZoopSpacing.m) {
                    Image(systemName: item.status == .satisfied ? "checkmark.circle.fill"
                          : item.status == .partial ? "circle.lefthalf.filled" : "circle")
                        .foregroundStyle(item.status == .satisfied ? StrandPalette.statusPositive : StrandPalette.textTertiary)
                    Text(engineText(item.label))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 8)
                    Text(engineText(item.detail))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            HStack(spacing: ZoopSpacing.l) {
                Button { showSettings = true } label: { Text(FitnessAgeStrings.openSettings) }
                    .font(StrandFont.ui(15, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Button {
                    guard !refreshing else { return }
                    refreshing = true
                    Task {
                        _ = await intelligence.recomputeFitnessAgeOnly()
                        await reload()
                        refreshing = false
                    }
                } label: {
                    if refreshing { ProgressView() } else { Text(FitnessAgeStrings.refresh) }
                }
                .font(StrandFont.ui(15, weight: .semibold))
                .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .padding(ZoopSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .zoopInsetSurface(radius: ZoopRadius.tile)
    }
}
#endif
