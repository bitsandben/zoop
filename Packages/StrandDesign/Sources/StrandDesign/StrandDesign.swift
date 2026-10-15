import SwiftUI
#if !os(watchOS)
import Charts   // Swift Charts isn't used by the watch app; the ChartProxy shim below is watchOS-excluded.
#endif

// MARK: - iOS-17 / macOS-14 deprecation shims
// iOS targets 17 and macOS 13, and these sources compile into both. The iOS 17 / macOS 14 `onChange(of:initial:_:)` and optional `ChartProxy.plotFrame` deprecate their
// predecessors, so a blind swap fails on macOS 13. These shims use the modern form where available and the legacy one otherwise, acknowledging each deprecation once.

public extension View {
    /// macOS-13-safe `onChange` that hands the closure the new value (single-parameter shim; call sites unchanged).
    @ViewBuilder
    func onChangeCompat<V: Equatable>(
        of value: V,
        perform action: @escaping (V) -> Void
    ) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.onChange(of: value) { _, newValue in action(newValue) }
        } else {
            self.legacyOnChange(of: value, perform: action)
        }
    }
}

private extension View {
    /// The legacy single-parameter `onChange`, isolated so its deprecation is acknowledged once; `@available` marks it deprecated only where the modern overload takes over.
    @available(iOS, introduced: 16.0, deprecated: 17.0)
    @available(macOS, introduced: 13.0, deprecated: 14.0)
    @ViewBuilder
    func legacyOnChange<V: Equatable>(
        of value: V,
        perform action: @escaping (V) -> Void
    ) -> some View {
        self.onChange(of: value, perform: action)
    }
}

#if !os(watchOS)
public extension ChartProxy {
    /// macOS-13-safe plot rect: the optional `plotFrame` on iOS 17 / macOS 14, else the deprecated `plotAreaFrame`. `.zero` on a nil anchor matches the pre-layout behaviour.
    func plotRectCompat(in geo: GeometryProxy) -> CGRect {
        if #available(iOS 17.0, macOS 14.0, *) {
            guard let frame = plotFrame else { return .zero }
            return geo[frame]
        } else {
            return geo[plotAreaFrame]
        }
    }
}
#endif

/// Strand design system: palette, typography, motion and signature components (Recovery Ring, Strain Gauge, Hypnogram, Trend/Sparkline charts, Year heat strip, cards, status chips).
///
/// Token entry points:
/// - `StrandPalette` — every semantic color token, recovery/strain sampling.
/// - `StrandFont` — the full type scale with tabular digits.
/// - `StrandMotion` — spring presets + durations.
public enum StrandDesign {
    public static let version = "0.1.0"
}
