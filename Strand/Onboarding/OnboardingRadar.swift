import SwiftUI
import StrandDesign

/// The pair step's radar: concentric rings, a sweeping wedge while a scan runs, a dot once bonded.
/// Decorative only; the status line beside it carries the state for VoiceOver.
struct OnboardingRadar: View {
    var active: Bool
    var bonded: Bool
    @State private var angle: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Low Power Mode / "Reduce motion in Zoop" hold the sweep still too.
    @ObservedObject private var motion = ZoopMotionState.shared
    private var poseStill: Bool { motion.poseStill(reduceMotion) }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                ForEach(1...3, id: \.self) { i in
                    Circle()
                        .stroke(StrandPalette.hairline, lineWidth: 1)
                        .frame(width: size * Double(i) / 3, height: size * Double(i) / 3)
                }
                if active {
                    wedge(size: size).rotationEffect(.degrees(angle))
                }
                Circle()
                    .fill(bonded ? StrandPalette.statusPositive : StrandPalette.accent)
                    .frame(width: 12, height: 12)
                if bonded {
                    Circle()
                        .fill(StrandPalette.statusPositive)
                        .frame(width: 10, height: 10)
                        .position(x: size * 0.70, y: size * 0.36)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
        .onAppear { if active { startSweep() } }
        .onChangeCompat(of: active) { if $0 { startSweep() } }
    }

    private func wedge(size: CGFloat) -> some View {
        let radius = size / 2
        return AngularGradient(colors: [StrandPalette.accent.opacity(0), StrandPalette.accent.opacity(0.4)],
                               center: .center, startAngle: .degrees(-50), endAngle: .degrees(0))
            .mask(
                Path { p in
                    let c = CGPoint(x: radius, y: radius)
                    p.move(to: c)
                    p.addArc(center: c, radius: radius, startAngle: .degrees(-50), endAngle: .degrees(0),
                             clockwise: false)
                    p.closeSubpath()
                }
            )
            .frame(width: size, height: size)
    }

    private func startSweep() {
        // Reduce Motion: the still wedge and rings already say "searching".
        guard !poseStill else { return }
        angle = 0
        withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { angle = 360 }
    }
}
