import Foundation
import StrandAnalytics

/// meta.json (schema v1): ties a strap log to the test profile that produced it, with build
/// provenance and the storage / DB-size block. snake_case wire keys; sortedKeys keeps output stable.
struct TestBundleMeta: Codable {
    let schema: Int                    // always 1
    let appVersion: String
    let platform: String               // "iOS" | "macOS" | "Android"
    let osVersion: String
    let strapModel: String?
    let source: [String]               // e.g. ["Live Bluetooth"]
    let testProfile: String            // TestDomain.id
    let profileStartedAt: String?      // ISO8601, from TestCentre.startedAt
    let questionnaire: [String: String]
    let build: Build
    let storage: Storage
    let redaction: String              // "v2"
    let truncated: Bool
    /// Report-completeness result: per ACTIVE domain, OK (killer trace landed, with a count) or
    /// INCOMPLETE. Empty on a non-test export. Built by CaptureCompleteness.evaluate over the redacted report.
    var captureCheck: [CaptureCheck] = []

    /// channel: AltStore / App Store / TestFlight / brew / GitHub / sideload; signed is false on sideloaded iOS.
    struct Build: Codable { let channel: String; let signed: Bool }

    /// db_bytes plus per-table row counts plus the raw-capture footprint.
    struct Storage: Codable {
        let dbBytes: Int; let rows: [String: Int]; let rawCaptureBytes: Int
        /// Estimated payload bytes per table, keyed as `rows` is (rows alone mislead for BLOB tables like
        /// `ppgWaveformSample`). A sampled lower bound with no index or page overhead; compare to `db_bytes`.
        let rowBytes: [String: Int]
        enum CodingKeys: String, CodingKey {
            case rows
            case dbBytes = "db_bytes", rawCaptureBytes = "raw_capture_bytes", rowBytes = "row_bytes"
        }
    }

    enum CodingKeys: String, CodingKey {
        case schema, platform, source, questionnaire, build, storage, redaction, truncated
        case appVersion = "app_version", osVersion = "os_version", strapModel = "strap_model"
        case testProfile = "test_profile", profileStartedAt = "profile_started_at"
        case captureCheck = "capture_check"
    }

    func encoded() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? e.encode(self)) ?? Data()
    }
}
