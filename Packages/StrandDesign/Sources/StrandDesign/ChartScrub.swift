#if !os(watchOS)
// The one touch-scrub mechanism every iOS chart uses. The watch draws no scrubbable charts, so the file is
// excluded there; on macOS the modifier is a no-op because the pointer hover already drives the readout.
import SwiftUI
#if os(iOS)
import UIKit
import UIKit.UIGestureRecognizerSubclass
#endif

// MARK: - Chart scrub (touch)
//
// Every chart answers a finger the same way: drag sideways (or rest the finger for a moment, then move)
// and a vertical rule plus a small value/time label follows the finger; lift and it clears.
//
// The gesture only claims the touch when the finger means it, so a chart never traps the page:
//  * A drag that starts mostly VERTICAL is refused at once, so the page scrolls as if the chart were not
//    there.
//  * A drag that starts mostly HORIZONTAL claims the touch, and a surrounding horizontal pager or carousel
//    waits for that decision rather than sliding sideways under the finger.
//  * A finger held still for `holdDuration` claims the touch too, after which it may move in any direction.
//
// On iOS 18 and later this is a UIKit recogniser (one decision point, failure requirements on the scroll
// views around it). iOS 17 falls back to a simultaneous SwiftUI drag that only acts on horizontal intent,
// which keeps vertical scrolling but cannot stop an enclosing pager.

/// Whether a chart scrub is engaged, readable by page-level swipe gestures (the Home day swipe) that live
/// outside UIKit's gesture arbitration and must ignore a drag that was really a scrub.
public enum ZoopChartScrubState {
    /// True from the moment a scrub engages until the finger lifts.
    public private(set) static var isActive = false
    private static var lastEnded = Date.distantPast

    /// True while scrubbing, or within a short grace period after the scrub ended (the page swipe's
    /// `onEnded` fires after the scrub's own end).
    public static var isActiveOrRecent: Bool {
        isActive || Date().timeIntervalSince(lastEnded) < 0.4
    }

    static func begin() { isActive = true }
    static func end() {
        if isActive { lastEnded = Date() }
        isActive = false
    }
}

/// How a chart's scrub may start.
public enum ZoopChartScrubStart: Sendable {
    /// A mostly horizontal drag, or a short hold. The default for every static chart.
    case horizontalDragOrHold
    /// Only a short hold. For charts whose plain horizontal drag already pans a zoomed window.
    case holdOnly
}

public extension View {
    /// Touch scrubbing for a chart. `onChange` receives the finger's location in this view's own
    /// coordinate space (attach it to the same view the chart's geometry is measured in, e.g. the
    /// `chartOverlay` GeometryReader's content); `onEnd` fires when the finger lifts or the touch is lost.
    ///
    /// Both callbacks run in a non-animating transaction, so the rule and label track the finger
    /// exactly and never slide or cross-fade between samples. No-op on macOS (pointer hover covers it).
    func zoopChartScrub(
        isEnabled: Bool = true,
        start: ZoopChartScrubStart = .horizontalDragOrHold,
        onChange: @escaping (CGPoint) -> Void,
        onEnd: @escaping () -> Void
    ) -> some View {
        modifier(ZoopChartScrubModifier(isEnabled: isEnabled, start: start, onChange: onChange, onEnd: onEnd))
    }
}

/// Apply a scrub update without animation: the readout must follow the finger, not ease after it.
func zoopScrubTransaction(_ body: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, body)
}

struct ZoopChartScrubModifier: ViewModifier {
    let isEnabled: Bool
    let start: ZoopChartScrubStart
    let onChange: (CGPoint) -> Void
    let onEnd: () -> Void

    #if os(iOS)
    /// iOS 17 fallback state: the drag has been judged a scrub / judged a scroll.
    @State private var engaged = false
    @State private var rejected = false
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        if !isEnabled {
            content
        } else if #available(iOS 18.0, *) {
            content.gesture(ChartScrubGesture(
                horizontalStart: start == .horizontalDragOrHold,
                onChange: { location in zoopScrubTransaction { onChange(location) } },
                onEnd: { zoopScrubTransaction { onEnd() } }))
        } else {
            content.simultaneousGesture(fallbackGesture)
        }
        #else
        content
        #endif
    }

    #if os(iOS)
    /// iOS 17: a simultaneous drag (so the enclosing scroll view keeps its own pan) that becomes a scrub only
    /// when its first movement is mostly horizontal. A hold-only chart keeps the press-and-hold sequence.
    private var fallbackGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                if !engaged {
                    guard !rejected else { return }
                    let dx = abs(value.translation.width), dy = abs(value.translation.height)
                    guard start == .horizontalDragOrHold, dx > dy * 1.2 else { rejected = true; return }
                    engaged = true
                    ZoopChartScrubState.begin()
                    StrandHaptic.selection.play()
                }
                zoopScrubTransaction { onChange(value.location) }
            }
            .onEnded { _ in
                let wasEngaged = engaged
                engaged = false
                rejected = false
                guard wasEngaged else { return }
                ZoopChartScrubState.end()
                zoopScrubTransaction { onEnd() }
            }
    }
    #endif
}

#if os(iOS)
/// One-finger recogniser that decides, once, whether a touch is a chart scrub.
///
/// Stays `.possible` until the finger either travels `slop` points (horizontal → begin, otherwise → fail)
/// or rests for `holdDuration` (→ begin). A second finger fails it so pinches stay with their owner.
final class ChartScrubRecognizer: UIGestureRecognizer {
    var allowsHorizontalStart = true
    var holdDuration: TimeInterval = 0.3
    private let slop: CGFloat = 8
    private var startPoint: CGPoint = .zero
    private var holdTimer: DispatchWorkItem?

    private var isTracking: Bool { state == .began || state == .changed }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if (event.allTouches?.count ?? touches.count) > 1 {
            finish(cancelled: true)
            return
        }
        guard let touch = touches.first else { return }
        startPoint = touch.location(in: view)
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.state == .possible else { return }
            self.state = .began
        }
        holdTimer?.cancel()
        holdTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration, execute: timer)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch = touches.first else { return }
        if isTracking {
            state = .changed
            return
        }
        guard state == .possible else { return }
        let point = touch.location(in: view)
        let dx = point.x - startPoint.x, dy = point.y - startPoint.y
        guard hypot(dx, dy) >= slop else { return }
        holdTimer?.cancel()
        state = (allowsHorizontalStart && abs(dx) > abs(dy) * 1.2) ? .began : .failed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        finish(cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        finish(cancelled: true)
    }

    private func finish(cancelled: Bool) {
        holdTimer?.cancel()
        holdTimer = nil
        if isTracking {
            state = cancelled ? .cancelled : .ended
        } else if state == .possible {
            state = .failed
        }
    }

    override func reset() {
        super.reset()
        holdTimer?.cancel()
        holdTimer = nil
    }
}

/// Bridges `ChartScrubRecognizer` into SwiftUI and arbitrates with the scroll views around the chart.
@available(iOS 18.0, *)
struct ChartScrubGesture: UIGestureRecognizerRepresentable {
    var horizontalStart: Bool
    var onChange: (CGPoint) -> Void
    var onEnd: () -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Scroll-view pans (the page's vertical scroll, a horizontal carousel or pager) wait for the scrub to
        /// decide. A vertical drag fails the scrub within a few points and the page scrolls; a horizontal one
        /// begins it and the carousel's pan then fails instead of sliding the cards.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer.view is UIScrollView
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> ChartScrubRecognizer {
        let recognizer = ChartScrubRecognizer()
        recognizer.allowsHorizontalStart = horizontalStart
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: ChartScrubRecognizer, context: Context) {
        recognizer.allowsHorizontalStart = horizontalStart
    }

    func handleUIGestureRecognizerAction(_ recognizer: ChartScrubRecognizer, context: Context) {
        switch recognizer.state {
        case .began:
            ZoopChartScrubState.begin()
            StrandHaptic.selection.play()
            onChange(context.converter.localLocation)
        case .changed:
            onChange(context.converter.localLocation)
        case .ended, .cancelled, .failed:
            ZoopChartScrubState.end()
            onEnd()
        default:
            break
        }
    }
}
#endif

// MARK: - Scrub readout

/// The shared scrub readout: a vertical rule at `x` through the whole chart, an optional dot on the line,
/// and the small value/time label kept inside the chart. Built from the hover toolkit pieces
/// (`CrosshairRule`, `HighlightDot`, `PositionedTooltip`) so touch and pointer read identically.
public struct ChartScrubReadout: View {
    public var x: CGFloat
    /// Where the series crosses the rule; nil draws no dot and anchors the label near the top.
    public var y: CGFloat?
    public var container: CGSize
    public var value: String
    public var label: String?
    public var accent: Color?

    public init(x: CGFloat, y: CGFloat?, container: CGSize, value: String, label: String? = nil, accent: Color? = nil) {
        self.x = x
        self.y = y
        self.container = container
        self.value = value
        self.label = label
        self.accent = accent
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            CrosshairRule(x: x, height: container.height)
            if let y, let accent {
                HighlightDot(color: accent).position(x: x, y: y)
            }
            PositionedTooltip(
                anchor: CGPoint(x: x, y: y ?? 0),
                container: container,
                tooltip: ChartTooltip(value: value, label: label, accent: accent))
        }
        .frame(width: container.width, height: container.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
