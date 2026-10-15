import SwiftUI
#if os(watchOS)
import WatchKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Strand Haptics (the tactile sibling of the Motion tokens)
//
// One sparse tactile vocabulary mirroring StrandMotion: Taptic on iOS, no-op on macOS. Confirmations and
// state landings only, never per-keystroke or per-frame.

public enum StrandHaptic {
    case selection   // segmented-pill / tab switch / toggle — light, frequent-safe
    case light       // a soft tap (alias kept for press-feedback call sites)
    case commit      // a primary action succeeded (save workout, finish interval)
    case success     // a meaningful milestone (bond success, breathe session done)
    case warning     // a soft "not allowed / invalid"

    #if os(watchOS)
    // watchOS has no UIKit feedback generators; map the vocabulary onto the closest `WKHapticType`.
    private func fire() {
        let device = WKInterfaceDevice.current()
        switch self {
        case .selection: device.play(.click)
        case .light:     device.play(.click)
        case .commit:    device.play(.success)
        case .success:   device.play(.success)
        case .warning:   device.play(.failure)
        }
    }
    #elseif canImport(UIKit)
    // Generators are cheap and UIKit pools the engine, so none are retained.
    private func fire() {
        switch self {
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        case .light:     UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .commit:    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case .success:   UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:   UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
    #endif

    /// Fires this haptic now. No-op on macOS.
    public func play() {
        #if os(watchOS)
        fire()
        #elseif canImport(UIKit)
        fire()
        #endif
    }
}

public extension View {
    /// Declarative haptic fired when `trigger` changes (iOS 17+ `.sensoryFeedback`; no-op elsewhere), for
    /// state-change cues such as score reveal or bond success.
    @ViewBuilder
    func strandHaptic<V: Equatable>(_ haptic: StrandHaptic, trigger: V) -> some View {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            self.sensoryFeedback(trigger: trigger) { _, _ in haptic.sensory }
        } else { self }
        #else
        self
        #endif
    }
}

#if os(iOS)
@available(iOS 17.0, *)
private extension StrandHaptic {
    var sensory: SensoryFeedback {
        switch self {
        case .selection: return .selection
        case .light:     return .impact(weight: .light)
        case .commit:    return .impact(weight: .heavy)
        case .success:   return .success
        case .warning:   return .warning
        }
    }
}
#endif
