#if os(iOS)
import SwiftUI
import StrandDesign

/// The fasting ring: an inset track and a rounded arc from 12 o'clock. Shared by the Fasting hero
/// (with clock marks on top) and the compact card on Today.
struct FastingProgressRing: View {
    let progress: Double
    let lineWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Strokes straddle the path, so inset by half the width to keep the ring inside its frame.
            Circle().stroke(StrandPalette.surfaceInset, lineWidth: lineWidth).padding(lineWidth / 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(StrandPalette.metricCyan, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(lineWidth / 2)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.6), value: progress)
        }
    }
}
#endif
