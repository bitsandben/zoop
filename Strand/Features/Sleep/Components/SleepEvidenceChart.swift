#if os(iOS)
import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign

// MARK: - Evidence chart

struct SleepEvidenceMarker: Hashable {
    let ts: Int
    let label: String
    let color: Color
}

/// Per-minute heart rate over `[from, to]` with the night's sleeping and awake levels as dashed lines,
/// wrist movement as faint bars along the floor, and labelled markers.
struct SleepEvidenceChart: View {
    let evidence: SleepOnsetEvidence
    let from: Int
    let to: Int
    let markers: [SleepEvidenceMarker]

    private struct Pt: Identifiable { let id: Int; let date: Date; let hr: Double?; let moving: Double? }

    private var points: [Pt] {
        let ev = evidence
        let i0 = max(0, (from - ev.seriesStartTs) / 60)
        let i1 = min(ev.minuteHR.count - 1, (to - ev.seriesStartTs) / 60)
        guard i1 > i0 else { return [] }
        return (i0...i1).map { i in
            Pt(id: i, date: Date(timeIntervalSince1970: TimeInterval(ev.seriesStartTs + i * 60)),
               hr: ev.minuteHR[i], moving: ev.minuteMoving[i])
        }
    }

    var body: some View {
        let pts = points
        let hrs = pts.compactMap(\.hr)
        let refs = [evidence.sleepLevelBpm, evidence.awakeBarBpm].compactMap { $0 }
        let lo0 = (hrs + refs).min() ?? 40, hi0 = (hrs + refs).max() ?? 100
        let pad = max(3, (hi0 - lo0) * 0.1)
        let floor = lo0 - pad - (hi0 - lo0 + 2 * pad) * 0.3   // room for the movement bars
        let hi = hi0 + pad
        let barTop = lo0 - pad
        Chart {
            ForEach(pts) { p in
                if let m = p.moving, m > 0 {
                    RectangleMark(x: .value("Time", p.date), yStart: .value("Floor", floor),
                                  yEnd: .value("Movement", floor + (barTop - floor) * min(1, m * 1.6)), width: 2)
                        .foregroundStyle(StrandPalette.textTertiary.opacity(0.5))
                }
            }
            ForEach(pts) { p in
                if let hr = p.hr {
                    LineMark(x: .value("Time", p.date), y: .value("Heart rate", hr))
                        .foregroundStyle(StrandPalette.metricRose)
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
            if let level = evidence.sleepLevelBpm {
                RuleMark(y: .value("Sleeping level", level))
                    .foregroundStyle(StrandPalette.restBright)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            if let bar = evidence.awakeBarBpm {
                RuleMark(y: .value("Awake level", bar))
                    .foregroundStyle(StrandPalette.metricRose.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            ForEach(markers, id: \.self) { m in
                RuleMark(x: .value("Marker", Date(timeIntervalSince1970: TimeInterval(m.ts))))
                    .foregroundStyle(m.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .annotation(position: .top, spacing: 2) {
                        Text(m.label)
                            .font(StrandFont.caption.weight(.semibold))
                            .foregroundStyle(m.color)
                    }
            }
        }
        .chartXScale(domain: Date(timeIntervalSince1970: TimeInterval(from))...Date(timeIntervalSince1970: TimeInterval(to)))
        .chartYScale(domain: floor...hi)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                if let d = v.as(Double.self), d >= barTop {
                    AxisGridLine().foregroundStyle(StrandPalette.hairline)
                    AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Heart rate and movement"))
    }
}
#endif
