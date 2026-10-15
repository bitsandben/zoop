import Foundation

// Content-driven breath sessions (stages, catalog, player): the app renders, protocols are content.
// Pure. Presence Process tempos are measured from public guides. See docs/FEATURES.md (Breathe).

/// How a protocol is driven in the UI.
public enum BreathProtocolMode: String, Equatable, Sendable {
    /// Fixed stages + haptic/visual pacer.
    case playable
    /// Education and session timer only, no auto-pacer (safety for variable techniques).
    case guided
}

/// Catalog grouping for the Breathe pace picker.
public enum BreathProtocolCategory: String, Equatable, Sendable {
    /// ANS / common breath protocols (public technique list).
    case ans
    /// Presence Process consciously-connected tempos.
    case presence
    /// Built-in Zoop biofeedback modes (Resonance / Calm); not in the catalog table.
    case biofeedback
}

/// One timed stage inside a playable protocol.
public struct BreathStage: Equatable, Sendable {
    public let type: BreathPhase
    /// Stage length in milliseconds (explicit; no BPM clamp).
    public let durationMs: Int
    /// Optional English UI label (e.g. nostril side); localize in the view.
    public let label: String?

    public init(type: BreathPhase, durationMs: Int, label: String? = nil) {
        self.type = type
        self.durationMs = max(0, durationMs)
        self.label = label
    }
}

/// One breath protocol: identity, English source strings for education, and optional stages.
public struct BreathProtocol: Equatable, Sendable, Identifiable {
    public let id: String
    /// Short pill / list title.
    public let title: String
    /// One-line tagline under the orb when idle.
    public let subtitle: String
    /// Background / how-to for the info sheet.
    public let edu: String
    /// Safety note / who should skip; nil if none.
    public let caution: String?
    /// Session length hint shown in the info sheet.
    public let sessionHint: String?
    public let mode: BreathProtocolMode
    public let category: BreathProtocolCategory
    /// Default session length when the user picks this pace (UI can override).
    public let recommendedDurationMs: Int
    /// Empty when `mode == .guided`.
    public let stages: [BreathStage]

    public init(id: String,
                title: String,
                subtitle: String,
                edu: String,
                caution: String? = nil,
                sessionHint: String? = nil,
                mode: BreathProtocolMode,
                category: BreathProtocolCategory,
                recommendedDurationMs: Int,
                stages: [BreathStage] = []) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.edu = edu
        self.caution = caution
        self.sessionHint = sessionHint
        self.mode = mode
        self.category = category
        self.recommendedDurationMs = max(0, recommendedDurationMs)
        self.stages = stages
    }

    /// Sum of one full stage cycle in ms (0 for guided).
    public var cycleDurationMs: Int {
        stages.reduce(0) { $0 + $1.durationMs }
    }
}

/// Haptic / phase cue list from a playable protocol for a fixed session window.
public enum BreathProtocolPlayer {

    public static let holdLoops: Int = 0
    public static let textOnlyLoops: Int = 0

    /// Felt buzz count for a stage type (matches `BreathPacer` for inhale/exhale).
    public static func loops(for phase: BreathPhase) -> Int {
        switch phase {
        case .inhale: return BreathPacer.inhaleLoops
        case .exhale: return BreathPacer.exhaleLoops
        case .hold, .textOnly: return 0
        }
    }

    /// Cues covering `[0, sessionMs)` by repeating the stage cycle. Guided protocols, empty stages or
    /// `sessionMs < 1` give `[]`. No new stage onset is scheduled once `offsetMs >= sessionMs`.
    public static func schedule(_ proto: BreathProtocol, sessionMs: Int) -> [BreathCue] {
        guard proto.mode == .playable else { return [] }
        guard sessionMs >= 1 else { return [] }
        let stages = proto.stages.filter { $0.durationMs > 0 }
        guard !stages.isEmpty else { return [] }

        let cycleMs = stages.reduce(0) { $0 + $1.durationMs }
        guard cycleMs > 0 else { return [] }

        var out: [BreathCue] = []
        var base = 0
        var guardCycles = 0
        let maxCycles = max(1, (sessionMs / cycleMs) + 2)
        while base < sessionMs && guardCycles < maxCycles {
            var offset = base
            for stage in stages {
                if offset >= sessionMs { break }
                out.append(BreathCue(
                    offsetMs: offset,
                    phase: stage.type,
                    loops: loops(for: stage.type),
                    label: stage.label
                ))
                offset += stage.durationMs
            }
            base += cycleMs
            guardCycles += 1
        }
        return out
    }
}
