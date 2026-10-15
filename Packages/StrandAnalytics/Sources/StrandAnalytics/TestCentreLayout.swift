import Foundation

/// Pure projection of the registry for the Test Centre screen's section 1 (domain test modes): priority
/// order (high, med, low; registry order stable inside a band) with `requires5MG` modes hidden off a
/// non-5/MG strap (#22).
public enum TestCentreLayout {

    /// Ranks a priority so high sorts before med before low.
    static func rank(_ p: TestPriority) -> Int {
        switch p {
        case .high: return 0
        case .med: return 1
        case .low: return 2
        }
    }

    /// Orders a mode list for the screen; stable within a priority band.
    public static func order(_ modes: [TestMode], is5MG: Bool) -> [TestMode] {
        modes
            .filter { is5MG || !$0.requires5MG }
            .enumerated()
            .sorted { a, b in
                let ra = rank(a.element.priority), rb = rank(b.element.priority)
                return ra == rb ? a.offset < b.offset : ra < rb
            }
            .map { $0.element }
    }

    /// The shipped registry projected for the current strap.
    public static func visibleModes(is5MG: Bool) -> [TestMode] {
        order(TestModeRegistry.all, is5MG: is5MG)
    }
}

public extension TestCentreLayout {

    /// The row status string: "Off" when inactive, "On" for a toggle mode, "Capturing K of N <unit>" for a
    /// guided mode. K is the per-mode count of DISTINCT days that mode produced a trace on (`capturedUnits`,
    /// #965), clamped to [0, target]. When nil it falls back to the elapsed-day proxy
    /// (`ceil(elapsedSeconds / 1 day)`, clamped to [1, target]) for previews.
    static func statusText(for mode: TestMode, active: Bool, elapsedSeconds: Double?,
                           capturedUnits: Int? = nil) -> String {
        guard active else { return "Off" }
        switch mode.capture {
        case .toggle:
            return "On"
        case let .guided(unit, defaultCount):
            let k: Int
            if let captured = capturedUnits {
                // Distinct captured days, clamped to [0, target].
                k = min(max(captured, 0), defaultCount)
            } else {
                // Elapsed-clock proxy, clamped to [1, target].
                let elapsed = max(0, elapsedSeconds ?? 0)
                let dayIndex = Int(ceil(elapsed / 86_400.0))
                k = min(max(dayIndex, 1), defaultCount)
            }
            return "Capturing \(k) of \(defaultCount) \(unit.rawValue)"
        }
    }
}
