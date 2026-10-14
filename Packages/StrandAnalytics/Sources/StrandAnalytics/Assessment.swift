import Foundation

/// One resolved fact: its value, how much history backs it, and why it reads the way it does.
///
/// Each fact the app shows (Recovery, Stress, Illness) has exactly one resolver in this package, and
/// that resolver returns an `Assessment` so a view never has to decide confidence or pick between two
/// sources itself. `value` is nil when the resolver declines to give a number (calibrating, no data);
/// `reason` is the engine's own vocabulary for the state, which the UI localizes.
public struct Assessment<Value: Equatable & Sendable, Reason: Equatable & Sendable>: Equatable, Sendable {
    public let value: Value?
    public let confidence: ScoreConfidence
    public let reason: Reason

    public init(value: Value?, confidence: ScoreConfidence, reason: Reason) {
        self.value = value
        self.confidence = confidence
        self.reason = reason
    }
}
