import Foundation

/// One resolved fact: its value, how much history backs it, and why it reads the way it does. Each
/// fact has one resolver returning an `Assessment`; `value` is nil when it declines to give a number,
/// and `reason` is the engine's vocabulary for the state, which the UI localizes.
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
