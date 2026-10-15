import Foundation
import WhoopProtocol
import OuraProtocol

/// Maps a batch of decoded `OuraEvent` onto the datastore's `Streams` shape so the live Oura source
/// persists through the same `StreamStore.insert` path as WHOOP, keyed by the ring's own `deviceId`.
/// Parallels `StandardHRMapping`.
///
/// Honest-data invariant: only the ring's decoded raw signals and open event tags map here; Oura's
/// encrypted readiness or sleep scores are never read. The `OuraHRV` 0x5D tag is the ring's own
/// RMSSD-derived signal, not a readiness score.
///
/// Every row is stamped at the batch's arrival wall-clock `ts` (unix seconds); decoded events carry
/// only a ring-clock `ringTimestamp`, so anchoring is the transport's job. An undecoded signal leaves
/// its stream empty, never faked.
///
/// Tier-B (unverified) events are dropped so they cannot feed scoring. The one explicit exception is
/// `.sleepPeriodInfo`'s `breath`, mapped to `resp`; it is kept out of the sleep stager at the read
/// (`OuraRespScale.forScoring`) because the stager expects a 1 Hz raw ADC waveform, not a per-window rate.
public enum OuraStreamMapping {
    /// WhoopEvent.kind for the ring's own HRV 0x5D tag: a run of `(u8 avg HR bpm, u8 avg RMSSD ms)` pairs,
    /// one per 5-min bucket, stored as `pair_index` / `hr_bpm` / `rmssd_ms`. Not Oura's readiness score
    /// and not Zoop's scoring RMSSD (reconstructed from `rr`). Each bucket gets its own timestamp so it
    /// survives the (deviceId, ts, kind) event key.
    public static let hrvEventKind = "OURA_HRV"
    /// WhoopEvent.kind for a decoded sleep-phase code (2-bit: awake/light/deep/rem).
    public static let sleepPhaseEventKind = "OURA_SLEEP_PHASE"
    /// WhoopEvent.kind for a decoded 0x47 motion_events window: the ring's own per-window summary
    /// (`orientation`, `motion_seconds`, `x`/`y`/`z`, `low_intensity`/`high_intensity`, the last two absent
    /// on a short record). Instrumentation only: never scored and never fed to the sleep stager, since 0x47
    /// is movement-gated.
    public static let motionEventKind = "OURA_MOTION"

    /// Builds a `Streams` from a batch of decoded Oura events, all stamped at the arrival wall-clock `ts`.
    ///   - `.hr` (0x55) to `hr`
    ///   - `.ibi` (0x44/0x60) to `rr`
    ///   - `.hrv` (0x5D) to `OURA_HRV` events, one per 5-min bucket
    ///   - `.spo2` (0x6F/0x70 only) to `spo2`, carrying the decoder's `unit` tag. 0x77 is a raw DC channel
    ///     on a different scale: decoded but not persisted, since blending scales into one column corrupts
    ///     any unit-blind consumer.
    ///   - `.temp` (0x46/0x75) to `skinTemp`
    ///   - `.sleepPhase` (0x4E/0x5A) to `OURA_SLEEP_PHASE` events
    ///   - `.battery` to `battery`
    ///   - `.sleepPeriodInfo` (0x6A, Tier B) to `resp`, `breath` only
    /// Other event cases are not folded into durable streams. In particular 0x50 activity/MET never mints a
    /// `steps` row: the formula is third-party and unvalidated, and MET is not a step count.
    public static func streams(from events: [OuraEvent], at ts: Int) -> Streams {
        var out = Streams()
        for e in events {
            switch e {
            case .hr(let v):
                // Only the decoded BPM. The push's IBI is skipped because the dedicated `.ibi` events are the R-R
                // source and a second RR row would double-count the interval.
                out.hr.append(HRSample(ts: ts, bpm: v.bpm))

            case .ibi(let v):
                // Carry the decoder's own channel tag. The ring reports the same heartbeats on more than one tag
                // (0x80, and 0x6E during SpO2 measurement), so an untagged store held about two copies of every
                // night. Both are real, so neither is dropped; the scoring read (`Reads.rrIntervals`) picks one and
                // the other stays as a cross-check. Nil stays nil: a channel is never guessed.
                out.rr.append(RRInterval(ts: ts, rrMs: v.ibiMs, srcChannel: rrChannel(v.channel)))

            case .hrv(let v):
                // The ring's own 0x5D bucket: average HR (bpm) and RMSSD (ms), both u8, unscaled. `pair_index` is the
                // position in the record. Scoring RMSSD still comes from the IBI stream. Keys and values match the
                // Kotlin twin byte for byte.
                //
                // Each bucket needs its own timestamp: the event PK is (deviceId, ts, kind), so pairs sharing the
                // record `ts` would collide and only one would survive.
                //
                // Order: the record's first pair is its oldest bucket and the record `ts` marks the END of the span,
                // so the last pair's 5 minutes end at `ts`. A bucket is an interval stamped at its start, hence
                // `count - index` (SpO2 uses `count - 1 - index` for instants). Validated against the median HR of
                // the 0x60 beats per 5-min window over three nights: r = +0.97/+0.96/+0.89 with this order, against
                // -0.08/+0.63/+0.11 for the reversed one.
                //
                // `count` is the record's original pair count, including a `00 00` pad dropped at decode, because
                // the offset is measured from the record's tail.
                let bucketTs = ts - (v.count - v.index) * 300
                out.events.append(WhoopEvent(ts: bucketTs, kind: hrvEventKind, payload: [
                    "pair_index": .int(v.index),
                    "hr_bpm": .int(v.hrBpm),
                    "rmssd_ms": .int(v.rmssdMs),
                ]))

            case .spo2(let v):
                // Persist only the 0x6F/0x70 channel (`unit == "raw"`, clusters at 95-105 like a real %SpO2). The 0x77
                // DC channel (`dc_raw`) is a raw PPG/perfusion signal on a wildly different scale (-9K to +11.7M), and
                // blending it into `red` corrupts any consumer that averages without a unit filter
                // (`AnalyticsEngine.nightlySpo2RawMeans`). It stays decoded and reachable from `oura-raw.jsonl`.
                // `SpO2Sample` is WHOOP-shaped two-channel, so the value goes on `red` and `ir` stays 0.
                guard v.unit == "raw" else { continue }

                // `unit` still travels onto the row (always "raw" past the guard) so downstream never assumes a %.
                //
                // Each sample needs its own second: `spo2Sample` is keyed (deviceId, ts), so 13 samples written at one
                // `ts` collided and 92% of a night was lost (the ring trims history once the offload is acked). Samples
                // are 1 Hz (13 per packet at a 13 s median interval) and laid backward from the record time, so the
                // last sample keeps the record's `ts`. `count == 1` yields offset 0. The Kotlin twin computes the same second.
                //
                // Collision-rare, not proof: a 12 s gap between two 13-sample records costs one sample at the
                // boundary (0.84% of samples over one overnight). `spo2Sample` inserts `ON CONFLICT DO NOTHING`, so
                // the anchor-exact older sample survives. Keeping both would need sub-second keys.
                let sampleTs = ts - max(0, v.count - 1 - v.index)
                out.spo2.append(SpO2Sample(ts: sampleTs, red: v.value, ir: 0, unit: v.unit))

            case .temp(let v):
                // The decoder yields degrees C. `SkinTempSample.raw` is integer centi-degrees C, the codebase-wide
                // scale (WHOOP @73 stores it and `AnalyticsEngine.skinTempFunnel` divides by 100), so an Oura night
                // reads on the same gates as a WHOOP night. The Kotlin twin stores the same celsius * 100.
                out.skinTemp.append(SkinTempSample(ts: ts, raw: Int((v.celsius * 100).rounded()), unit: "centi_c"))

            case .sleepPhase(let v):
                // Each code arrives with its reconstructed time as `ts` (`OuraHypnogramAssembler` lays the burst's
                // codes backward at the 30 s SleepNet epoch from the anchored end; the record envelope marks the
                // write moment, not the sleep). 30 s spacing makes every code a distinct (deviceId, ts, kind) row.
                // The raw 2-bit code persists unchanged; `index` (position within the wire record) is kept for audit.
                out.events.append(WhoopEvent(ts: ts, kind: sleepPhaseEventKind, payload: [
                    "phase": .int(v.stage.rawValue),
                    "index": .int(v.index),
                ]))

            case .battery(let v):
                out.battery.append(BatterySample(
                    ts: ts,
                    soc: Double(v.percent),
                    mv: v.voltageMv,
                    charging: v.charging))

            case .motionEvent(let m):
                // 0x47 motion window to an OURA_MOTION event: instrumentation, not a gravity stream. 0x47 is
                // movement-gated, a shape mismatch for the gravity-stillness `SleepStager`, so it never enters
                // `gravitySample` and is never scored. One row per window at its anchored `ts`; keys match the Kotlin
                // twin. `low_/high_intensity` are omitted on a short record, never faked to 0.
                var payload: [String: ParsedValue] = [
                    "orientation": .int(m.orientation),
                    "motion_seconds": .int(m.motionSeconds),
                    "x": .int(m.avgX), "y": .int(m.avgY), "z": .int(m.avgZ),
                ]
                if let lo = m.lowIntensity { payload["low_intensity"] = .int(lo) }
                if let hi = m.highIntensity { payload["high_intensity"] = .int(hi) }
                out.events.append(WhoopEvent(ts: ts, kind: motionEventKind, payload: payload))

            case .sleepPeriodInfo(let v):
                // 0x6A `breath` to a `respSample` row under the ring's deviceId; on a ring night these rows supply the
                // scored `dailyMetric.respRateBpm` (`AnalyticsEngine.vendorRespRateBpm` takes the in-session median).
                // `OuraRespScale.forScoring` still refuses them at the staging read: a per-window rate is the wrong
                // shape for a peak detector expecting a ~1 Hz raw ADC waveform.
                //
                // Stored because `breath` is the ring's own measurement, not a signal Zoop derives, so the question
                // is whether the decode is right: 3,493 records over four nights, every value an exact multiple of
                // 0.125. It matches the same wearer's Oura app export in distribution (median 14.75 vs 15.25/min) and
                // reproduces the vendor's offset against a WHOOP worn the same nights (r = +0.60 / +0.75).
                //
                // `raw` is milli-breaths-per-minute (`OuraRespScale`, exact for every wire value). `respSample.raw`
                // otherwise holds a WHOOP ADC waveform sample, so the row's owner is what tells the two apart.
                //
                // Not persisted: `averageHrBpm` (same `hr` series, different cadence and provenance);
                // `breathVariability` / `mzci` / `dzci` / `cv` (uninterpreted); `sleepState` (no documented code
                // meaning). The scored slot is fed in `AnalyticsEngine`, not here. The Kotlin twin stores the same integer.
                out.resp.append(RespSample(ts: ts,
                                           raw: OuraRespScale.milliBpm(fromBreathsPerMin: v.breathsPerMin),
                                           unit: OuraRespScale.unitTag))

            case .motion, .state, .timeSync, .rtcBeacon, .debugText, .tierB, .activityInfo,
                 .realStepsFields:
                // Not a durable stream row: timeSync/rtcBeacon anchor the transport clock, motion/state/debug are
                // diagnostics, and Tier-B / `.activityInfo` / `.realStepsFields` are unverified and must never feed
                // scoring or steps. 0x50 activity/MET never mints a `steps` row (third-party formula, MET is not a
                // step count), and `.realStepsFields` holds inputs to Oura's step model, not a count.
                continue
            }
        }
        return out
    }

    /// Groups already-stamped events into one batch per timestamp, keeping arrival order and the
    /// first-appearance order of the timestamps.
    ///
    /// `StreamStore.insert`'s `ord` counter is batch-local: a beat's position among beats sharing its
    /// second within one insert. One event per insert would write `ord = 0` on every row, the read would
    /// fall back to sorting a second's beats by value, and RMSSD would be biased down. Events keep their
    /// relative order inside a batch so `ord` counts in emission order.
    public static func batched(_ stamped: [(event: OuraEvent, ts: Int)]) -> [(ts: Int, events: [OuraEvent])] {
        var order: [Int] = []
        var byTs: [Int: [OuraEvent]] = [:]
        for s in stamped {
            if byTs[s.ts] == nil {
                order.append(s.ts)
                byTs[s.ts] = []
            }
            byTs[s.ts]?.append(s.event)
        }
        return order.map { (ts: $0, events: byTs[$0] ?? []) }
    }

    /// Translates the protocol layer's `OuraIBIChannel` to the store's `RRSourceChannel`.
    ///
    /// Two enums because `OuraProtocol` does not depend on `WhoopProtocol`. Written case by case rather
    /// than via `rawValue` so a case added on one side is a compile error, not a silent nil.
    public static func rrChannel(_ c: OuraIBIChannel?) -> RRSourceChannel? {
        switch c {
        case .greenQuality:  return .greenQuality
        case .spo2Ibi:       return .spo2Ibi
        case .ibiAmplitude:  return .ibiAmplitude
        case .ibiBare:       return .ibiBare
        case nil:            return nil
        }
    }
}
