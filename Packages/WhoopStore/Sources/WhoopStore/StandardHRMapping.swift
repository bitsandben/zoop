import Foundation
import WhoopProtocol

/// Maps a single standard-BLE Heart-Rate reading (0x2A37) onto the datastore's `Streams` shape so a
/// generic strap source persists through the same `StreamStore.insert` path as WHOOP.
///
/// A chest strap reports only HR, optional R-R intervals and contact flags over 0x2A37; every other
/// stream is left empty.
public enum StandardHRMapping {
    /// `event.kind` for a standard BLE sensor-contact reading, stored in the generic event table (no schema migration).
    public static let contactEventKind = "STANDARD_HR_CONTACT"

    /// Whether this reading should record a contact event, given the last one recorded.
    ///
    /// Contact is a state that changes a few times a day while 0x2A37 arrives at ~1 Hz; one row per
    /// reading would store ~86,400 identical rows a day, and the read side only needs the changes.
    /// `previous == nil` records, so every session opens with its starting state.
    public static func shouldRecordContact(previous: StandardHRContact?,
                                           current: StandardHRContact) -> Bool {
        previous != current
    }

    /// Builds a `Streams` carrying one HR sample and zero or more R-R intervals, all stamped at the same `ts` (unix seconds).
    public static func samples(fromHR hr: Int, rr: [Int], contact: StandardHRContact? = nil,
                               at ts: Int) -> Streams {
        let events = contact.map { [
            WhoopEvent(ts: ts, kind: contactEventKind, payload: ["contact": .string($0.rawValue)])
        ] } ?? []
        return Streams(
            hr: [HRSample(ts: ts, bpm: hr)],
            rr: rr.map { RRInterval(ts: ts, rrMs: $0) },
            events: events
        )
    }

    /// Parses a persisted `STANDARD_HR_CONTACT` `payloadJSON`. Throws on malformed JSON or a missing or
    /// unknown `contact` field, so a parse failure is not the same as "no contact event".
    public static func contactSample(ts: Int, payloadJSON: String) throws -> StandardHRContactSample {
        let payload = try JSONDecoder().decode([String: ParsedValue].self, from: Data(payloadJSON.utf8))
        guard case let .string(raw)? = payload["contact"] else {
            throw ContactSampleError.missingContact
        }
        guard let contact = StandardHRContact(rawValue: raw) else {
            throw ContactSampleError.unknownContact(raw)
        }
        return StandardHRContactSample(ts: ts, contact: contact)
    }

    public enum ContactSampleError: Error, Equatable {
        case missingContact
        case unknownContact(String)
    }
}

/// One persisted standard-BLE sensor-contact reading. Legacy HR rows have no companion event and are
/// absent from this stream rather than guessed.
public struct StandardHRContactSample: Equatable, Sendable {
    public let ts: Int
    public let contact: StandardHRContact
    public init(ts: Int, contact: StandardHRContact) {
        self.ts = ts
        self.contact = contact
    }
}
