#if !os(watchOS)
// Uses .onContinuousHover + .help() (unavailable on watchOS), so the view is excluded there.
import SwiftUI

// MARK: - Year Heat Strip
// GitHub-style year grid (columns = weeks, rows = weekdays), each cell tinted by the day's recovery via the recovery gradient.
// Empty days are a faint inset square; hover shows SwiftUI's built-in help tooltip.

/// A day's recovery datum for the heat strip.
public struct RecoveryDay: Identifiable, Sendable {
    public let id = UUID()
    public var date: Date
    /// Recovery 0...100, or nil if no data for that day.
    public var score: Double?

    public init(date: Date, score: Double?) {
        self.date = date
        self.score = score
    }
}

public struct YearHeatStrip: View {

    public var days: [RecoveryDay]
    public var cellSize: CGFloat
    public var spacing: CGFloat
    public var showsMonthLabels: Bool
    /// Whether hovering a cell highlights it with a ring and shows a tooltip
    /// (date + score + recovery state word). Defaults on.
    public var showsHover: Bool
    /// Formats a day's score for the tooltip's bold line.
    public var valueFormat: (Double) -> String

    /// The week-column layout, built once in `init` from the sorted days (`buildWeeks()` reads `.component` for up to 365 days) rather than per `body` eval, which re-ran on every hover.
    private let weeks: [Week]

    public init(
        days: [RecoveryDay],
        cellSize: CGFloat = 12,
        spacing: CGFloat = 3,
        showsMonthLabels: Bool = true,
        showsHover: Bool = true,
        valueFormat: @escaping (Double) -> String = { "Recovery \(Int($0.rounded()))" }
    ) {
        let sorted = days.sorted { $0.date < $1.date }
        self.days = sorted
        self.cellSize = cellSize
        self.spacing = spacing
        self.showsMonthLabels = showsMonthLabels
        self.showsHover = showsHover
        self.valueFormat = valueFormat
        self.weeks = YearHeatStrip.buildWeeks(from: sorted)
    }

    // The grid layout constants used both for drawing and hover hit-testing.
    private let gutterWidth: CGFloat = 24
    private let monthLabelHeight: CGFloat = 10

    /// Hovered cell as (weekIndex, row), or nil.
    @State private var hoverCell: (week: Int, row: Int)? = nil

    // Fixed Monday-first Gregorian calendar stored as a constant: a computed property allocated a Calendar ~730 times per render (`buildWeeks()` runs on every render, including each hover).
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2 // Monday-first columns read nicely
        return c
    }()

    // Group days into week columns. weekday 0 = Monday ... 6 = Sunday.
    private struct Week: Identifiable {
        let id = UUID()
        var cells: [RecoveryDay?] // length 7, indexed by weekday row
        var monthLabel: String?
    }

    /// Pure: group the sorted days into Monday-first week columns. Static so `init` can call it.
    private static func buildWeeks(from days: [RecoveryDay]) -> [Week] {
        guard let first = days.first?.date else { return [] }
        var weeks: [Week] = []
        var current = Week(cells: Array(repeating: nil, count: 7), monthLabel: nil)
        var lastMonth = -1
        let firstRow = weekdayRow(first)
        var filledThisWeek = 0
        for _ in 0..<firstRow { filledThisWeek += 1 }

        for day in days {
            let row = weekdayRow(day.date)
            if row == 0 && filledThisWeek > 0 {
                weeks.append(current)
                current = Week(cells: Array(repeating: nil, count: 7), monthLabel: nil)
                filledThisWeek = 0
            }
            current.cells[row] = day
            // tag month label at the first cell of a new month
            let month = calendar.component(.month, from: day.date)
            if month != lastMonth {
                current.monthLabel = monthShort(day.date)
                lastMonth = month
            }
            filledThisWeek += 1
        }
        if filledThisWeek > 0 { weeks.append(current) }
        return weeks
    }

    private static func weekdayRow(_ date: Date) -> Int {
        // Map Calendar weekday (1=Sun...7=Sat) to Monday-first 0...6.
        let wd = calendar.component(.weekday, from: date)
        return (wd + 5) % 7
    }

    private static func monthShort(_ date: Date) -> String {
        let f = DateFormatterCache.month
        return f.string(from: date)
    }

    private let rowLabels = ["Mon", "", "Wed", "", "Fri", "", "Sun"]

    public var body: some View {
        // `weeks` is built once in init. Total drawn size lets the hover overlay sit over the grid and clamp the tooltip.
        let gridWidth = gridOriginX + CGFloat(weeks.count) * (cellSize + spacing) - spacing
        let gridHeight = gridOriginY + 7 * (cellSize + spacing) - spacing

        VStack(alignment: .leading, spacing: spacing) {
            if showsMonthLabels {
                // #1021: month labels boxed to one cell width (~12pt) truncated ("Jul" → "J…"). Position each absolutely at its column x with `.fixedSize` so it overflows right
                // into the empty columns before the next month; grid cells stay column-aligned in their own HStack.
                ZStack(alignment: .topLeading) {
                    // Reserve the row's height + full grid width so the ZStack lays out over the columns.
                    Color.clear.frame(width: gridWidth, height: monthLabelHeight)
                    ForEach(Array(weeks.enumerated()), id: \.element.id) { weekIndex, week in
                        if let label = week.monthLabel, !label.isEmpty {
                            Text(label)
                                .font(.system(size: 8))
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize()
                                .offset(x: gridOriginX + CGFloat(weekIndex) * (cellSize + spacing))
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: spacing) {
                VStack(alignment: .trailing, spacing: spacing) {
                    ForEach(0..<7, id: \.self) { r in
                        Text(rowLabels[r])
                            .font(.system(size: 8))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: gutterWidth, height: cellSize, alignment: .trailing)
                    }
                }
                ForEach(Array(weeks.enumerated()), id: \.element.id) { weekIndex, week in
                    VStack(spacing: spacing) {
                        ForEach(0..<7, id: \.self) { row in
                            cell(week.cells[row], isHovered: isHovered(weekIndex, row))
                        }
                    }
                }
            }
        }
        .frame(width: gridWidth, height: gridHeight, alignment: .topLeading)
        .overlay(hoverOverlay(weeks: weeks, gridSize: CGSize(width: gridWidth, height: gridHeight)))
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard showsHover else { return }
            switch phase {
            case .active(let location):
                hoverCell = cellIndex(at: location, weekCount: weeks.count)
            case .ended:
                hoverCell = nil
            }
        }
        // Touch: hold, then drag across the days. Hold-only because the strip sits in a horizontal
        // scroll view, which keeps sideways drags for itself.
        .zoopChartScrub(isEnabled: showsHover, start: .holdOnly,
                        onChange: { hoverCell = cellIndex(at: $0, weekCount: weeks.count) },
                        onEnd: { hoverCell = nil })
        // ONE collapsed VoiceOver element for the calendar: a per-day a11y node built an O(days) semantics subtree re-copied on every scroll (a #707 OOM contributor). `children: .ignore` makes it O(1).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(axSummary))
    }

    /// A spoken one-line summary of the whole strip for VoiceOver.
    private var axSummary: String {
        let scored = days.compactMap { $0.score }
        guard let lo = scored.min(), let hi = scored.max() else {
            return String(localized: "Recovery calendar, no data", bundle: .module)
        }
        let avg = scored.reduce(0, +) / Double(scored.count)
        return String(localized: "Recovery calendar, \(scored.count) days, average \(Int(avg.rounded())), low \(Int(lo.rounded())), high \(Int(hi.rounded()))", bundle: .module)
    }

    // MARK: Grid geometry

    /// x of the first week column (after the weekday gutter + HStack spacing).
    private var gridOriginX: CGFloat { gutterWidth + spacing }
    /// y of the first cell row (below the optional month-label row).
    private var gridOriginY: CGFloat { showsMonthLabels ? monthLabelHeight + spacing : 0 }

    private func isHovered(_ week: Int, _ row: Int) -> Bool {
        guard let h = hoverCell else { return false }
        return h.week == week && h.row == row
    }

    /// Map a local cursor location to a (week, row) cell, or nil if outside the
    /// grid or in the inter-cell gaps.
    private func cellIndex(at point: CGPoint, weekCount: Int) -> (week: Int, row: Int)? {
        let stride = cellSize + spacing
        let lx = point.x - gridOriginX
        let ly = point.y - gridOriginY
        guard lx >= 0, ly >= 0 else { return nil }
        let week = Int(lx / stride)
        let row = Int(ly / stride)
        guard week >= 0, week < weekCount, row >= 0, row < 7 else { return nil }
        // Reject hits in the spacing gutter between cells.
        let withinX = lx - CGFloat(week) * stride
        let withinY = ly - CGFloat(row) * stride
        guard withinX <= cellSize, withinY <= cellSize else { return nil }
        return (week, row)
    }

    /// Centre of a cell in local coordinates.
    private func cellCenter(week: Int, row: Int) -> CGPoint {
        let stride = cellSize + spacing
        return CGPoint(
            x: gridOriginX + CGFloat(week) * stride + cellSize / 2,
            y: gridOriginY + CGFloat(row) * stride + cellSize / 2
        )
    }

    // MARK: Hover overlay (ring + tooltip)

    @ViewBuilder
    private func hoverOverlay(weeks: [Week], gridSize: CGSize) -> some View {
        if showsHover, let h = hoverCell, h.week < weeks.count,
           let day = weeks[h.week].cells[h.row], let score = day.score {
            let center = cellCenter(week: h.week, row: h.row)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(StrandPalette.hairlineStrong, lineWidth: 1.5)
                    .frame(width: cellSize + 3, height: cellSize + 3)
                    .position(center)
                PositionedTooltip(
                    anchor: center,
                    container: gridSize,
                    tooltip: ChartTooltip(
                        value: valueFormat(score),
                        label: "\(DateFormatterCache.day.string(from: day.date)) · \(StrandPalette.recoveryState(score))",
                        accent: StrandPalette.recoveryColor(score)
                    )
                )
            }
            .animation(StrandMotion.fade, value: h.week)
            .animation(StrandMotion.fade, value: h.row)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func cell(_ day: RecoveryDay?, isHovered: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2.5)
        if let day, let score = day.score {
            shape
                .fill(StrandPalette.recoveryColor(score))
                .frame(width: cellSize, height: cellSize)
                .opacity(isHovered ? 1.0 : (hoverCell == nil ? 1.0 : 0.78))
                .help("\(DateFormatterCache.day.string(from: day.date)) · recovery \(Int(score.rounded()))")
                // No per-cell a11y element (the strip is one collapsed element); `.help` stays as a macOS pointer tooltip.
        } else if day != nil {
            shape
                .fill(StrandPalette.surfaceInset)
                .overlay(shape.stroke(StrandPalette.hairline.opacity(0.6), lineWidth: 0.5))
                .frame(width: cellSize, height: cellSize)
        } else {
            shape
                .fill(Color.clear)
                .frame(width: cellSize, height: cellSize)
        }
    }
}

// Small cached formatters (creating DateFormatter is expensive).
private enum DateFormatterCache {
    static let month: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM"; return f
    }()
    static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()
}

#if DEBUG
private func sampleYear() -> [RecoveryDay] {
    let cal = Calendar.current
    let today = Date()
    return (0..<365).map { i in
        let date = cal.date(byAdding: .day, value: -(364 - i), to: today)!
        // Some gaps + a wavy recovery profile.
        let gap = (i % 23 == 0)
        let v = 55 + 28 * sin(Double(i) / 11.0) + Double((i * 31) % 17) - 8
        return RecoveryDay(date: date, score: gap ? nil : max(2, min(99, v)))
    }
}

#Preview("YearHeatStrip") {
    VStack(alignment: .leading, spacing: 12) {
        Text("Recovery — past year").strandOverline()
        Text("Hover a cell: ring + date, score and recovery-state tooltip.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        YearHeatStrip(days: sampleYear())
    }
    .padding(28)
    .frame(width: 900, height: 240)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
#endif
