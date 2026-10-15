import SwiftUI
import StrandAnalytics
import StrandDesign

// MARK: - Smart alarm nights (Test Centre)
//
// Whether the app could act during each smart-alarm night, from `SmartAlarmNightLog`. The words come from
// `SmartAlarmNightText`, the same place the planner's morning line comes from.

struct SmartAlarmNightsView: View {
    @ObservedObject private var log = SmartAlarmNightLog.shared
    @State private var now = Int(Date().timeIntervalSince1970)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZoopSpacing.cardGap) {
                if log.nights.isEmpty {
                    ZoopEmptyState(systemImage: "alarm",
                                   title: "No smart alarm nights yet",
                                   message: "Turn on the alarm with a wake window; each night is listed here the morning after.")
                } else {
                    if let summary = SmartAlarmNightText.summary(log.nights, now: now) {
                        ContentCard {
                            Text(summary)
                                .font(ZoopType.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    ZoopSectionHeader("Nights", subtitle: "Newest first, the last 30 nights.")
                    ListCard {
                        ForEach(Array(log.nights.enumerated()), id: \.element.id) { idx, night in
                            NavigationLink { SmartAlarmNightDetailView(deadline: night.deadline) } label: {
                                SmartAlarmNightRow(night: night, now: now)
                            }
                            .buttonStyle(.plain)
                            .listCardRow(isFirst: idx == 0)
                        }
                    }
                }
            }
            .padding(.horizontal, ZoopSpacing.gutter)
            .padding(.vertical, ZoopSpacing.m)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .zoopPushedScreen(title: "Smart alarm nights")
        .onAppear { now = Int(Date().timeIntervalSince1970) }
    }
}

struct SmartAlarmNightRow: View {
    let night: SmartAlarmNight
    let now: Int

    var body: some View {
        let status = SmartAlarmNightText.coverage(night.coverage(now: now, intervalS: SmartAlarmNightText.checkInterval))
        HStack(alignment: .top, spacing: ZoopSpacing.m) {
            Image(systemName: status.icon)
                .foregroundStyle(SmartAlarmNightTone.color(status.tone))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
                Text("\(SmartAlarmNightText.day(night.deadline)) · \(SmartAlarmNightText.mode(night.settings.mode))")
                    .font(ZoopType.body.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(status.text)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                if let outcome = SmartAlarmNightText.outcome(night, now: now) {
                    Text(outcome)
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                if let live = SmartAlarmNightText.liveLine(night, now: now) {
                    Text(live)
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(ZoopType.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, ZoopSpacing.m)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct SmartAlarmNightDetailView: View {
    let deadline: Int
    @ObservedObject private var log = SmartAlarmNightLog.shared
    @State private var now = Int(Date().timeIntervalSince1970)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZoopSpacing.cardGap) {
                if let night = log.night(deadline: deadline) {
                    header(night)
                    ZoopSectionHeader("Timeline")
                    ListCard {
                        let entries = SmartAlarmNightText.timeline(night, now: now)
                        ForEach(Array(entries.enumerated()), id: \.element.id) { idx, e in
                            entryRow(e).listCardRow(isFirst: idx == 0)
                        }
                    }
                }
            }
            .padding(.horizontal, ZoopSpacing.gutter)
            .padding(.vertical, ZoopSpacing.m)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .zoopPushedScreen(title: "Night")
    }

    private func header(_ night: SmartAlarmNight) -> some View {
        let status = SmartAlarmNightText.coverage(night.coverage(now: now, intervalS: SmartAlarmNightText.checkInterval))
        return ContentCard {
            VStack(alignment: .leading, spacing: ZoopSpacing.s) {
                Label(status.text, systemImage: status.icon)
                    .font(ZoopType.headline)
                    .foregroundStyle(SmartAlarmNightTone.color(status.tone))
                Text("\(SmartAlarmNightText.mode(night.settings.mode)) · \(SmartAlarmNightText.clock(night.windowStart))–\(SmartAlarmNightText.clock(night.deadline))")
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let outcome = SmartAlarmNightText.outcome(night, now: now) {
                    Text(outcome).font(ZoopType.body).foregroundStyle(StrandPalette.textSecondary)
                }
                ForEach([SmartAlarmNightText.liveLine(night, now: now), SmartAlarmNightText.evaluationsLine(night)]
                    .compactMap { $0 }, id: \.self) { line in
                    Text(line)
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func entryRow(_ e: SmartAlarmNightText.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ZoopSpacing.m) {
            Text(SmartAlarmNightText.clock(e.at))
                .font(ZoopType.caption.monospacedDigit())
                .foregroundStyle(StrandPalette.textTertiary)
            VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
                Text(e.title)
                    .font(ZoopType.body)
                    .foregroundStyle(e.tone == .neutral ? StrandPalette.textPrimary : SmartAlarmNightTone.color(e.tone))
                    .fixedSize(horizontal: false, vertical: true)
                if let d = e.detail {
                    Text(d)
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, ZoopSpacing.s)
        .accessibilityElement(children: .combine)
    }
}

enum SmartAlarmNightTone {
    static func color(_ t: SmartAlarmNightText.Tone) -> Color {
        switch t {
        case .positive: return StrandPalette.statusPositive
        case .warning: return StrandPalette.statusWarning
        case .critical: return StrandPalette.statusCritical
        case .neutral: return StrandPalette.textSecondary
        }
    }
}
