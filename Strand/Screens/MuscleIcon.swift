import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Muscle icon (Zoop)
//
// A small anatomical crop for one `MuscleLoad.Group`: a stylised front or back figure drawn once in a
// 200 × 400 frame (`MuscleFigure`), each muscle a smooth closed curve through a handful of points, and
// each icon a square window onto that figure with the group's muscles filled in `highlight`. The body
// reads in two greys (silhouette, then the muscles on it), so the highlighted group is the only colour.

struct MuscleIcon: View {
    let group: MuscleLoad.Group
    var highlight: Color = StrandPalette.statusPositive
    var size: CGFloat = 44

    var body: some View {
        Canvas { ctx, canvasSize in
            let crop = MuscleFigure.crop(group)
            let s = canvasSize.width / crop.width
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: -crop.minX, y: -crop.minY)
            let side = MuscleFigure.side(group)
            for part in MuscleFigure.silhouette { ctx.fill(part, with: .color(MuscleIcon.bodyFill)) }
            for m in MuscleFigure.muscles(side) {
                ctx.fill(m.path, with: .color(m.group == group ? highlight : MuscleIcon.muscleFill))
            }
        }
        .frame(width: size, height: size)
        .mask {
            // Soft edges where the crop cuts through the body, so it reads as a window, not a cutout.
            RadialGradient(colors: [.black, .black, .black.opacity(0)], center: .center,
                           startRadius: 0, endRadius: size * 0.64)
        }
        .accessibilityHidden(true)
    }

    /// The silhouette: a step above the card surface.
    static var bodyFill: Color { StrandPalette.hairlineStrong }
    /// Muscles that are not the target: a step above the silhouette.
    static var muscleFill: Color { StrandPalette.textTertiary.opacity(0.55) }
}

// MARK: - Figure

enum MuscleFigure {
    enum Side { case front, back }

    struct Muscle {
        let group: MuscleLoad.Group?
        let path: Path
    }

    static func side(_ g: MuscleLoad.Group) -> Side {
        switch g {
        case .chest, .shoulders, .biceps, .forearms, .core, .quads: return .front
        case .triceps, .upperBack, .lats, .lowerBack, .glutes, .hamstrings, .calves: return .back
        }
    }

    /// The square window each icon shows, in figure coordinates.
    static func crop(_ g: MuscleLoad.Group) -> CGRect {
        switch g {
        case .chest:      return CGRect(x: 46, y: 50, width: 108, height: 108)
        case .shoulders:  return CGRect(x: 38, y: 46, width: 124, height: 124)
        case .biceps:     return CGRect(x: 18, y: 68, width: 92, height: 92)
        case .triceps:    return CGRect(x: 18, y: 68, width: 92, height: 92)
        case .forearms:   return CGRect(x: 8, y: 132, width: 92, height: 92)
        case .core:       return CGRect(x: 50, y: 98, width: 100, height: 100)
        case .upperBack:  return CGRect(x: 44, y: 44, width: 112, height: 112)
        case .lats:       return CGRect(x: 44, y: 70, width: 112, height: 112)
        case .lowerBack:  return CGRect(x: 50, y: 118, width: 100, height: 100)
        case .glutes:     return CGRect(x: 46, y: 168, width: 108, height: 108)
        case .quads:      return CGRect(x: 44, y: 196, width: 112, height: 112)
        case .hamstrings: return CGRect(x: 44, y: 212, width: 112, height: 112)
        case .calves:     return CGRect(x: 46, y: 282, width: 108, height: 108)
        }
    }

    // MARK: Silhouette

    /// Separate pieces, filled one by one so overlaps never cancel out under the winding rule.
    static let silhouette: [Path] = {
        var p: [Path] = [Path(ellipseIn: CGRect(x: 84, y: 6, width: 32, height: 42))]
        p.append(smooth([(91, 40), (109, 40), (111, 58), (114, 66), (86, 66), (89, 58)]))
        p.append(symmetric([(100, 58), (82, 62), (64, 68), (58, 84), (62, 112), (68, 140), (72, 166),
                             (70, 190), (68, 212), (100, 222)]))
        for arm in [
            smooth([(66, 68), (50, 74), (42, 96), (41, 124), (44, 150), (60, 154), (65, 128), (68, 100)]),
            smooth([(44, 144), (37, 168), (35, 194), (38, 216), (50, 217), (55, 192), (61, 166), (61, 146)]),
            smooth([(37, 213), (34, 228), (39, 244), (48, 244), (52, 228), (50, 213)]),
            smooth([(70, 196), (65, 236), (68, 272), (73, 300), (74, 330), (77, 362), (79, 384), (93, 384),
                    (94, 360), (97, 328), (96, 300), (98, 262), (100, 222)]),
            smooth([(78, 380), (74, 392), (82, 398), (96, 396), (94, 380)]),
        ] {
            p.append(arm)
            p.append(arm.applying(mirror))
        }
        return p
    }()

    // MARK: Muscles

    static func muscles(_ side: Side) -> [Muscle] {
        side == .front ? front : back
    }

    private static let shoulder: [(CGFloat, CGFloat)] =
        [(68, 69), (55, 72), (46, 84), (44, 100), (49, 110), (57, 100), (64, 86), (72, 75)]
    private static let forearm: [(CGFloat, CGFloat)] =
        [(47, 156), (41, 172), (39, 194), (41, 210), (48, 210), (53, 190), (58, 170), (58, 157)]

    private static let front: [Muscle] = pairs([
        (.shoulders, shoulder),
        (.chest, [(98, 72), (86, 69), (73, 75), (66, 88), (69, 103), (80, 112), (92, 113), (98, 108)]),
        (.biceps, [(57, 106), (49, 116), (46, 134), (49, 148), (58, 149), (63, 132), (63, 114)]),
        (.forearms, forearm),
        (.core, [(85, 118), (74, 122), (71, 146), (74, 170), (77, 192), (85, 198), (87, 172), (87, 142)]),
        (.quads, [(73, 212), (68, 236), (69, 262), (74, 287), (82, 298), (90, 296), (95, 280), (97, 252),
                  (96, 228), (89, 216)]),
        (nil, [(77, 312), (75, 332), (78, 356), (82, 372), (87, 370), (89, 346), (88, 322), (83, 310)]),
    ]) + abs

    /// Six blocks of the rectus abdominis, a gap down the midline.
    private static let abs: [Muscle] = {
        var out: [Muscle] = []
        for (y0, y1) in [(117.0, 136.0), (139.0, 157.0), (160.0, 180.0)] {
            let r = CGRect(x: 89, y: y0, width: 9.5, height: y1 - y0)
            let p = Path(roundedRect: r, cornerRadius: 4, style: .continuous)
            out.append(Muscle(group: .core, path: p))
            out.append(Muscle(group: .core, path: p.applying(mirror)))
        }
        out.append(Muscle(group: .core, path: symmetric([(100, 183), (89, 183), (91, 198), (100, 212)])))
        return out
    }()

    private static let back: [Muscle] = [
        Muscle(group: .upperBack, path: symmetric([(100, 46), (93, 56), (80, 63), (68, 70), (78, 78),
                                                   (88, 90), (95, 106), (100, 118)])),
    ] + pairs([
        (.shoulders, shoulder),
        (.triceps, [(55, 104), (46, 114), (44, 132), (47, 148), (57, 150), (62, 132), (61, 112)]),
        (.forearms, forearm),
        (.lats, [(71, 92), (66, 110), (69, 134), (77, 156), (88, 170), (94, 158), (92, 134), (87, 114),
                 (81, 100)]),
        (.lowerBack, [(98, 128), (94, 132), (91, 158), (88, 186), (92, 196), (98, 194)]),
        (.glutes, [(98, 200), (85, 198), (74, 205), (70, 222), (74, 239), (87, 245), (98, 240)]),
        (.hamstrings, [(74, 249), (70, 266), (73, 288), (80, 300), (88, 300), (94, 284), (97, 264),
                       (96, 250), (86, 250)]),
        (.calves, [(78, 310), (73, 326), (75, 346), (81, 360), (87, 358), (93, 345), (95, 326), (91, 311),
                   (84, 306)]),
    ])

    // MARK: Geometry helpers

    private static let mirror = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 200, ty: 0)

    private static func pairs(_ list: [(MuscleLoad.Group?, [(CGFloat, CGFloat)])]) -> [Muscle] {
        list.flatMap { g, pts -> [Muscle] in
            let p = smooth(pts)
            return [Muscle(group: g, path: p), Muscle(group: g, path: p.applying(mirror))]
        }
    }

    /// A closed shape symmetric about x = 100, from its left half traced top-centre to bottom-centre.
    private static func symmetric(_ left: [(CGFloat, CGFloat)]) -> Path {
        let right = left.dropFirst().dropLast().reversed().map { (200 - $0.0, $0.1) }
        return smooth(left + right)
    }

    /// A closed Catmull-Rom curve through `pts`.
    private static func smooth(_ pts: [(CGFloat, CGFloat)]) -> Path {
        let p = pts.map { CGPoint(x: $0.0, y: $0.1) }
        let n = p.count
        var path = Path()
        guard n > 2 else { return path }
        path.move(to: p[0])
        for i in 0..<n {
            let p0 = p[(i - 1 + n) % n], p1 = p[i], p2 = p[(i + 1) % n], p3 = p[(i + 2) % n]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.closeSubpath()
        return path
    }
}
