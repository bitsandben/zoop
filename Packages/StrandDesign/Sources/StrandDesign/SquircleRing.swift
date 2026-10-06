import SwiftUI

// MARK: - Squircle ring
//
// The score ring from the redesign concept: a rounded-square outline rather than a circle. The path
// starts at the top centre and runs clockwise, so trimming it to a fraction fills the ring the way a
// circular gauge would.

/// A rounded square traced clockwise from the top centre. `cornerFraction` is the corner radius as a
/// share of the shorter side; `smoothing` pulls the corner's control points toward the corner, so
/// lower values read squarer and 0.45 is close to a circular arc.
public struct SquircleShape: Shape {
    public var cornerFraction: CGFloat
    public var smoothing: CGFloat

    public init(cornerFraction: CGFloat = 0.46, smoothing: CGFloat = 0.36) {
        self.cornerFraction = cornerFraction
        self.smoothing = smoothing
    }

    public func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) * cornerFraction
        let c = r * smoothing
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r),
                   control1: CGPoint(x: rect.maxX - c, y: rect.minY),
                   control2: CGPoint(x: rect.maxX, y: rect.minY + c))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                   control1: CGPoint(x: rect.maxX, y: rect.maxY - c),
                   control2: CGPoint(x: rect.maxX - c, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                   control1: CGPoint(x: rect.minX + c, y: rect.maxY),
                   control2: CGPoint(x: rect.minX, y: rect.maxY - c))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                   control1: CGPoint(x: rect.minX, y: rect.minY + c),
                   control2: CGPoint(x: rect.minX + c, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// The upper half of a squircle, open at the bottom: the stress gauge's arch. Traced from the bottom
/// of the left side, over the top, down to the bottom of the right side.
public struct SquircleArch: Shape {
    public var cornerFraction: CGFloat
    public var smoothing: CGFloat

    public init(cornerFraction: CGFloat = 0.42, smoothing: CGFloat = 0.3) {
        self.cornerFraction = cornerFraction
        self.smoothing = smoothing
    }

    public func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height * 2) * cornerFraction
        let c = r * smoothing
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                   control1: CGPoint(x: rect.minX, y: rect.minY + c),
                   control2: CGPoint(x: rect.minX + c, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r),
                   control1: CGPoint(x: rect.maxX - c, y: rect.minY),
                   control2: CGPoint(x: rect.maxX, y: rect.minY + c))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return p
    }
}

/// A squircle score ring: a dim track with the filled share drawn over it in `tint`.
public struct SquircleRing: View {
    public var fraction: Double
    public var tint: Color
    public var lineWidth: CGFloat
    public var track: Color

    public init(fraction: Double, tint: Color, lineWidth: CGFloat = 7,
                track: Color = ZoopVisualStyle.ringTrack) {
        self.fraction = fraction
        self.tint = tint
        self.lineWidth = lineWidth
        self.track = track
    }

    public var body: some View {
        ZStack {
            SquircleShape()
                .stroke(track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            SquircleShape()
                .trim(from: 0, to: CGFloat(min(max(fraction, 0), 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .padding(lineWidth / 2)
    }
}
