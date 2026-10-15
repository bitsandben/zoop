#if !os(watchOS)
// The one touch-scrub mechanism every iOS chart uses. Excluded on watchOS; a no-op on macOS (pointer hover drives the readout).
import SwiftUI
#if os(iOS)
import UIKit
import UIKit.UIGestureRecognizerSubclass
#endif

// MARK: - Chart scrub (touch)
//
// Dragging sideways (or resting the finger, then moving) shows a vertical rule plus a value/time label.
// The gesture claims the touch only when the finger means it: a mostly VERTICAL drag is refused so the
// page scrolls; a mostly HORIZONTAL drag claims it (enclosing pagers wait for that decision); a hold of
// `holdDuration` claims it too. iOS 18+ uses a UIKit recogniser with failure requirements on surrounding
// scroll views; iOS 17 falls back to a simultaneous SwiftUI drag that cannot stop an enclosing pager.

/// Whether a chart scrub is engaged, for page-level swipe gestures (Home day swipe) outside UIKit's arbitration.
public enum ZoopChartScrubState {
    /// True from scrub engage until the finger lifts.
    public private(set) static var isActive = false
    private static var lastEnded = Date.distantPast

    /// True while scrubbing or shortly after, since the page swipe's `onEnded` fires after the scrub's own end.
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
    /// A mostly horizontal drag, or a short hold (default).
    case horizontalDragOrHold
    /// Only a short hold, for charts whose horizontal drag already pans a zoomed window.
    case holdOnly
}

public extension View {
    /// Touch scrubbing for a chart. `onChange` receives the finger location in this view's coordinate space
    /// (attach to the view the chart geometry is measured in); `onEnd` fires on lift or lost touch. Callbacks
    /// run non-animated so the readout tracks the finger. No-op on macOS.
    func zoopChartScrub(
        isEnabled: Bool = true,
        start: ZoopChartScrubStart = .horizontalDragOrHold,
        onChange: @escaping (CGPoint) -> Void,
        onEnd: @escaping () -> Void
    ) -> some View {
        modifier(ZoopChartScrubModifier(isEnabled: isEnabled, start: start, onChange: onChange, onEnd: onEnd))
    }
}

/// Applies a scrub update without animation.
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
    /// iOS 17 fallback: the drag has been judged a scrub / a scroll.
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
    /// iOS 17: a simultaneous drag (the enclosing scroll view keeps its pan) that becomes a scrub only on mostly horizontal first movement.
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
/// One-finger recogniser that decides once whether a touch is a chart scrub: begins on a horizontal
/// travel past `slop` or a `holdDuration` rest, fails otherwise; a second finger fails it (pinches).
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

/// Bridges `ChartScrubRecognizer` into SwiftUI and arbitrates with surrounding scroll views.
@available(iOS 18.0, *)
struct ChartScrubGesture: UIGestureRecognizerRepresentable {
    var horizontalStart: Bool
    var onChange: (CGPoint) -> Void
    var onEnd: () -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Scroll-view pans wait for the scrub to decide: vertical fails it and the page scrolls; horizontal begins it and the carousel pan fails.
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

/// The shared scrub readout: a vertical rule at `x`, an optional dot, and a value/time label kept inside
/// the chart, built from the hover toolkit so touch and pointer read identically.
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
