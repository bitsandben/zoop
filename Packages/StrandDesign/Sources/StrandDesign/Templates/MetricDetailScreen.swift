import SwiftUI

// MARK: - MetricDetailScreen (CONCEPT §1.1, §2.3, §2.4)
//
// The page every "tap a number" push lands on: the hero readout (tap → explainer sheet), what the
// metric is, the 30-day trend against the personal band, then the feature's own sections. It is a
// pushed screen: inline title from the readout's label, content below the bar, flat canvas.
//
//     MetricDetailScreen(model.hrv, explanation: model.hrvExplanation,
//                        takeaway: "Your HRV has been above your range for 5 days.") {
//         ZoopSectionHeader("What moves it")
//         ListCard { ... }
//     }

public struct MetricDetailScreen<Sections: View>: View {
    private let readout: MetricReadout
    private let explanation: MetricExplanation?
    private let takeaway: Text?
    private let sections: Sections
    @State private var showsExplainer = false

    /// `explanation` nil hides the info affordance, the "what it is" block and the trend.
    /// `takeaway` is the trend's one-line "so what" (§7.4).
    public init(
        _ readout: MetricReadout,
        explanation: MetricExplanation? = nil,
        takeaway: LocalizedStringKey? = nil,
        @ViewBuilder sections: () -> Sections
    ) {
        self.readout = readout
        self.explanation = explanation
        self.takeaway = takeaway.map { Text($0) }
        self.sections = sections()
    }

    @_disfavoredOverload
    public init(
        _ readout: MetricReadout,
        explanation: MetricExplanation? = nil,
        takeaway: LocalizedStringResource?,
        @ViewBuilder sections: () -> Sections
    ) {
        self.readout = readout
        self.explanation = explanation
        self.takeaway = takeaway.map { Text($0) }
        self.sections = sections()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZoopSpacing.cardGap) {
                hero
                if let explanation {
                    about(explanation)
                    trend(explanation)
                }
                sections
            }
            .padding(.horizontal, ZoopSpacing.gutter)
            .padding(.top, ZoopSpacing.s)
            .padding(.bottom, ZoopSpacing.xxl)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle(Text(readout.label))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showsExplainer) {
            if let explanation {
                MetricExplainerSheet(readout, explanation: explanation)
                    #if os(iOS)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    #endif
            }
        }
    }

    @ViewBuilder
    private var hero: some View {
        HeroCard {
            if explanation != nil {
                Button { showsExplainer = true } label: { MetricHero(readout, showsInfo: true) }
                    .buttonStyle(.plain)
            } else {
                MetricHero(readout, showsInfo: false)
            }
        }
    }

    private func about(_ explanation: MetricExplanation) -> some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            ZoopSectionHeader(MetricStrings.whatItIs)
                .padding(.top, ZoopSpacing.m)
            ContentCard {
                Text(explanation.whatItIs)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(explanation.method.name)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func trend(_ explanation: MetricExplanation) -> some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            ZoopSectionHeader(MetricStrings.trend)
                .padding(.top, ZoopSpacing.m)
            if explanation.trend.isEmpty {
                ZoopEmptyState(systemImage: "chart.xyaxis.line",
                               title: TemplateStrings.trendEmptyTitle,
                               message: TemplateStrings.trendEmptyMessage)
            } else {
                ContentCard {
                    MetricTrendChart(readout: readout, points: explanation.trend)
                    if let takeaway {
                        takeaway
                            .font(ZoopType.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

public extension MetricDetailScreen where Sections == EmptyView {
    init(_ readout: MetricReadout, explanation: MetricExplanation? = nil, takeaway: LocalizedStringKey? = nil) {
        self.init(readout, explanation: explanation, takeaway: takeaway) { EmptyView() }
    }
}

#if DEBUG
#Preview("Metric detail · dark") {
    NavigationStack {
        MetricDetailScreen(MetricSamples.hrvSolid, explanation: MetricSamples.explanation,
                           takeaway: "Above your range on 5 of the last 7 days.") {
            ZoopSectionHeader("Recent nights")
            ListCard {
                MetricRow(MetricSamples.rhrProvisional)
                Rectangle().fill(StrandPalette.hairline).frame(height: 1)
                MetricRow(MetricSamples.respStale)
            }
        }
    }
    .preferredColorScheme(.dark)
}

#Preview("Metric detail · calibrating · pastel DE") {
    NavigationStack {
        MetricDetailScreen(MetricSamples.recoveryCalibrating) {
            ZoopCalibratingState(title: "Learning your baseline",
                                 message: "Each night sharpens your personal range.",
                                 nightsCollected: 2,
                                 milestones: [.init(nights: 4, title: "First score"),
                                              .init(nights: 14, title: "Fully calibrated")])
        }
    }
    .zoopTheme(ZoopTheme.pastel.rawValue)
    .environment(\.locale, Locale(identifier: "de_DE"))
    .preferredColorScheme(.light)
}
#endif
