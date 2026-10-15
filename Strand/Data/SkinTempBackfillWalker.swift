import Foundation
import StrandAnalytics
import WhoopStore
import WhoopProtocol

/// I/O layer that backfills `skinTempC` for nights outside the 21-night `analyzeRecent` window. The pure
/// half (attribution, plan) lives in `StrandAnalytics/SkinTempBackfill.swift`.
///
/// Mirrors the scoring pass's per-night reads and calls the same `skinTempFunnel`, so a backfilled
/// absolute is byte-identical to what scoring would have stored. Runs on demand from the Test Centre
/// (an automatic run risks a long first launch on a deep history); one page is 50 nights.
///
/// The write is fill-only (`WhoopStore.fillSkinTempC` fills a NULL, never upserts a rebuilt row), so
/// `skinTempDevC` and every other scored field are untouched. An `actor` rather than `@MainActor`
/// because the multi-page walk has no UI state and should not compete with the UI thread.
actor SkinTempBackfillWalker {

    struct FilledNight: Sendable {
        let day: String
        let skinTempC: Double
    }

    struct DeclinedNight: Sendable {
        let day: String
        let reason: String
    }

    struct PassResult: Sendable {
        let filled: [FilledNight]
        let declined: [DeclinedNight]
        let noRawData: [String]
        let moreRemaining: Bool
    }

    private let store: WhoopStore
    private let computedId: String

    init(store: WhoopStore) {
        self.store = store
        self.computedId = Repository.whoopSource + "-zoop"
    }

    /// Runs one page of the backfill; call with increasing `page` until `moreRemaining` is false.
    /// `windowAnchorRaw` is the WHOOP 4.0 anchor from the CURRENT scoring window (nil for a 5/MG);
    /// `tzOffsetSeconds` is seconds east of UTC.
    func runPage(page: Int, pageSize: Int = 50,
                 windowAnchorRaw: Double?,
                 tzOffsetSeconds: Int) async -> PassResult {
        let candidates = await candidateNights()
        let pageCandidates = SkinTempBackfill.page(candidates, page: page, pageSize: pageSize)
        if pageCandidates.isEmpty {
            return PassResult(filled: [], declined: [], noRawData: [], moreRemaining: false)
        }

        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        let regDevices = (try? registry.all()) ?? []
        let activeId = (try? registry.activeDeviceId()) ?? Repository.whoopSource

        var filled: [FilledNight] = []
        var declined: [DeclinedNight] = []
        var noRawData: [String] = []

        for candidate in pageCandidates {
            let owner = await IntelligenceEngine.resolveDayOwner(
                day: candidate.day, from: candidate.from, to: candidate.to,
                store: store, devices: regDevices, activeId: activeId,
                registry: registry, fallbackDeviceId: Repository.whoopSource)

            let family = IntelligenceEngine.skinTempFamily(forOwner: owner, devices: regDevices)
            let tolerance = IntelligenceEngine.skinTempWornToleranceSec(forOwner: owner, devices: regDevices)

            let skin = (try? await store.skinTempSamples(
                deviceId: owner, from: candidate.from, to: candidate.to,
                limit: StreamReadCap.skin)) ?? []
            if skin.isEmpty {
                noRawData.append(candidate.day)
                continue
            }
            let hr = (try? await store.hrSamples(
                deviceId: owner, from: candidate.from, to: candidate.to,
                limit: StreamReadCap.hr)) ?? []
            let persisted = (try? await store.sleepSessions(
                deviceId: owner, from: candidate.from, to: candidate.to,
                limit: 4000)) ?? []
            let sessions = persisted.compactMap { AnalyticsEngine.sleepSession(fromProvided: $0) }

            // Local midnight: `dayString(ts, offsetSec:) == day` iff `(ts + offsetSec)` is in `[dayStart, +86400)`,
            // the same shift the scoring pass uses.
            let dayStart = Self.localMidnightUnix(forDay: candidate.day, tzOffsetSeconds: tzOffsetSeconds)

            let result = SkinTempBackfill.computeNight(
                candidate: candidate,
                sessions: sessions,
                hr: hr,
                skinTemp: skin,
                family: family,
                windowAnchorRaw: windowAnchorRaw,
                dayStart: dayStart,
                wornToleranceSec: tolerance)

            if let abs = result.skinTempC {
                // Fill-only: can only fill a NULL, never overwrite a measured value.
                _ = try? await store.fillSkinTempC(deviceId: computedId, day: candidate.day, skinTempC: abs)
                filled.append(FilledNight(day: candidate.day, skinTempC: abs))
            } else {
                declined.append(DeclinedNight(day: candidate.day, reason: result.declineReason ?? "unknown"))
            }
        }

        let moreRemaining = pageCandidates.count == pageSize
        return PassResult(filled: filled, declined: declined, noRawData: noRawData,
                          moreRemaining: moreRemaining)
    }

    private func candidateNights() async -> [SkinTempBackfill.NightCandidate] {
        let rows = (try? await store.dailyMetrics(
            deviceId: computedId, from: "0000-01-01", to: "9999-12-31")) ?? []
        let tzOffset = TimeZone.current.secondsFromGMT()
        let now = Int(Date().timeIntervalSince1970)
        return rows
            .filter { $0.skinTempDevC != nil && $0.skinTempC == nil }
            .sorted { $0.day < $1.day }
            .map { row in
                let dayStart = Self.localMidnightUnix(forDay: row.day, tzOffsetSeconds: tzOffset)
                let from = dayStart - StreamReadCap.lookbackSeconds
                let to = min(dayStart + 86_400, now)  // don't read past now for today's partial night
                return SkinTempBackfill.NightCandidate(day: row.day, from: from, to: to,
                                                        owner: Repository.whoopSource)
            }
    }

    static func localMidnightUnix(forDay day: String, tzOffsetSeconds: Int) -> Int {
        let parts = day.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return 0 }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        comps.hour = 0; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone(identifier: "UTC")
        let utcMidnight = Calendar(identifier: .gregorian).date(from: comps) ?? Date()
        return Int(utcMidnight.timeIntervalSince1970) - tzOffsetSeconds
    }

    // MARK: - Self-contained entry point (the call site)

    struct BackfillResult: Sendable {
        let filled: [FilledNight]
        let declined: [DeclinedNight]
        let noRawData: [String]
        let windowAnchorRaw: Double?
        let reachedEnd: Bool
        var filledCount: Int { filled.count }
        var declinedCount: Int { declined.count }
        var noRawDataCount: Int { noRawData.count }
    }

    /// Runs the full backfill: resolves the 4.0 window anchor, then pages through candidate nights until a page
    /// is empty or `maxPages` is reached. The single entry point for the Test Centre action.
    func runBackfill(maxDays: Int = 21, maxPages: Int = 10) async -> BackfillResult {
        let tzOffset = TimeZone.current.secondsFromGMT()
        let now = Int(Date().timeIntervalSince1970)
        let nowLocalMidnight = Self.localMidnightUnix(
            forDay: Self.dayKey(now: now, tzOffsetSeconds: tzOffset), tzOffsetSeconds: tzOffset)
        // Anchor is learned window-wide (not per-night) with the same bounds as `analyzeRecent`'s skin anchor scan.
        let scanFrom = nowLocalMidnight - (maxDays - 1) * 86_400 - StreamReadCap.lookbackSeconds
        let scanTo = nowLocalMidnight + 18 * 3_600
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        let activeId = (try? registry.activeDeviceId()) ?? Repository.whoopSource
        let regDevices = (try? registry.all()) ?? []
        let family = IntelligenceEngine.skinTempFamily(forOwner: activeId, devices: regDevices)
        let windowAnchorRaw: Double?
        if family == .whoop4 {
            let windowSkin = (try? await store.skinTempSamples(
                deviceId: activeId, from: scanFrom, to: scanTo,
                limit: StreamReadCap.skin)) ?? []
            windowAnchorRaw = Whoop4SkinTemp.deviceAnchorRaw(windowSkin.map { $0.raw })
        } else {
            windowAnchorRaw = nil
        }
        var filled: [FilledNight] = []
        var declined: [DeclinedNight] = []
        var noRawData: [String] = []
        var reachedEnd = false
        for page in 0..<maxPages {
            let r = await runPage(page: page, windowAnchorRaw: windowAnchorRaw,
                                  tzOffsetSeconds: tzOffset)
            filled.append(contentsOf: r.filled)
            declined.append(contentsOf: r.declined)
            noRawData.append(contentsOf: r.noRawData)
            if !r.moreRemaining {
                reachedEnd = true
                break
            }
        }
        return BackfillResult(filled: filled, declined: declined, noRawData: noRawData,
                              windowAnchorRaw: windowAnchorRaw, reachedEnd: reachedEnd)
    }

    private static func dayKey(now: Int, tzOffsetSeconds: Int) -> String {
        let comps = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(now + tzOffsetSeconds)))
        let y = comps.year ?? 0, m = comps.month ?? 0, d = comps.day ?? 0
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}
