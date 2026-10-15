import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Mindfulness section (Training page)
//
// Answers "how is my mental practice going, and does it do anything?": practice volume against the
// user's normal week, then the measured effect on heart rate, HRV and stress, then the latest sessions.
// Everything comes from `MindfulnessModel`; every number opens its explainer.

struct MindfulnessSection: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var model = MindfulnessModel()
    /// The Training page's workouts, so the rows are not read twice.
    let workouts: [WorkoutRow]

    @State private var explainer: MindfulMetric?
    @State private var meditating = false

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.cardGap) {
            ZoopSectionHeader(MindfulnessStrings.title, subtitle: MindfulnessStrings.subtitle)
            if model.loaded && !model.hasPractice {
                ZoopEmptyState(systemImage: "leaf", title: MindfulnessStrings.emptyTitle,
                               message: MindfulnessStrings.emptyMessage)
            } else if model.loaded {
                TileGrid {
                    ForEach(model.practice) { metric in
                        Button { explainer = metric } label: { MetricTile(metric.readout) }.buttonStyle(.plain)
                    }
                }
            }
            actions
            if model.hasPractice { effectCard; recentCard }
        }
        .padding(.top, ZoopSpacing.s)
        .task(id: TaskKey(seq: repo.refreshSeq, count: workouts.count)) {
            await model.refresh(repo: repo, workouts: workouts)
        }
        .onReceive(NotificationCenter.default.publisher(for: MindfulSessionLog.didChange)) { _ in
            Task { await model.refresh(repo: repo, workouts: workouts) }
        }
        .sheet(item: $explainer) { MetricExplainerSheet($0.readout, explanation: $0.explanation) }
        .meditationCover(isPresented: $meditating)
    }

    private struct TaskKey: Equatable { let seq: Int; let count: Int }

    /// Two equal quick starts: the meditation timer and the breathing exercise.
    private var actions: some View {
        HStack(spacing: ZoopSpacing.m) {
            Button { meditating = true } label: {
                Label { Text(MindfulnessStrings.meditate) } icon: { Image(systemName: "leaf") }
            }
            .buttonStyle(ZoopButtonStyle(.secondary, fullWidth: true))
            #if os(iOS)
            NavigationLink(value: TabRoute.breathe) {
                Label { Text(MindfulnessStrings.breathe) } icon: { Image(systemName: "wind") }
            }
            .buttonStyle(ZoopButtonStyle(.secondary, fullWidth: true))
            #endif
        }
    }

    private var effectCard: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            ZoopSectionHeader(MindfulnessStrings.effectTitle, subtitle: MindfulnessStrings.effectSubtitle)
            ListCard {
                ForEach(Array(model.effect.enumerated()), id: \.element.id) { index, metric in
                    Button { explainer = metric } label: { MetricRow(metric.readout) }
                        .buttonStyle(.plain)
                        .overlay(alignment: .top) {
                            if index > 0 { Rectangle().fill(StrandPalette.hairline).frame(height: 1) }
                        }
                }
            }
        }
        .padding(.top, ZoopSpacing.s)
    }

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            ZoopSectionHeader(MindfulnessStrings.recentTitle)
            ListCard {
                ForEach(Array(model.recent.enumerated()), id: \.element.id) { index, row in
                    MindfulSessionRowView(row: row).listCardRow(isFirst: index == 0)
                }
            }
        }
        .padding(.top, ZoopSpacing.s)
    }
}

/// One past session: kind and when on the left, duration and measured heart-rate change on the right.
private struct MindfulSessionRowView: View {
    let row: MindfulSessionRow

    var body: some View {
        HStack(spacing: ZoopSpacing.m) {
            Image(systemName: Self.icon(row.kind))
                .font(ZoopType.headline)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
                Text(row.title).font(ZoopType.body).foregroundStyle(StrandPalette.textPrimary)
                Text(row.detail).font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: ZoopSpacing.s)
            VStack(alignment: .trailing, spacing: ZoopSpacing.xs) {
                Text(row.duration).font(ZoopType.body).foregroundStyle(StrandPalette.textPrimary)
                if let response = row.response {
                    Text(response).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    static func icon(_ kind: MindfulPractice.Kind) -> String {
        switch kind {
        case .meditation: return "leaf"
        case .yoga: return "figure.yoga"
        case .breathing: return "wind"
        case .pilates: return "figure.pilates"
        case .stretching: return "figure.flexibility"
        case .taiChi: return "figure.taichi"
        }
    }
}
