import Foundation
import GRDB

extension WhoopStore {
    /// The schema migrator. v1 creates decoded-stream tables (durable) + the raw outbox.
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "device") { t in
                t.column("id", .text).primaryKey()
                t.column("mac", .text)
                t.column("name", .text)
                t.column("firstSeen", .integer)
                t.column("lastSeen", .integer)
            }
            try db.create(table: "hrSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("bpm", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "rrInterval") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("rrMs", .integer).notNull()
                t.primaryKey(["deviceId", "ts", "rrMs"])
            }
            try db.create(table: "event") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("payloadJSON", .text).notNull()
                t.primaryKey(["deviceId", "ts", "kind"])
            }
            try db.create(table: "battery") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("soc", .double)
                t.column("mv", .integer)
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "rawBatch") { t in
                t.column("batchId", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("capturedAt", .integer).notNull()
                t.column("deviceClockRef", .integer).notNull()
                t.column("wallClockRef", .integer).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer).notNull()
                t.column("frameCount", .integer).notNull()
                t.column("byteSize", .integer).notNull()
                t.column("framesBlob", .blob).notNull()
                t.column("syncedAt", .integer)
            }
        }
        migrator.registerMigration("v2") { db in
            try db.create(table: "cursors") { t in
                t.column("name", .text).primaryKey()
                t.column("value", .integer)
            }
        }
        migrator.registerMigration("v3") { db in
            // type-47 biometric streams, PK (deviceId, ts).
            try db.create(table: "spo2Sample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("red", .integer).notNull()
                t.column("ir", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "skinTempSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("raw", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "respSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("raw", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "gravitySample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("x", .double).notNull()
                t.column("y", .double).notNull()
                t.column("z", .double).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }
        migrator.registerMigration("v4") { db in
            // sleepSession: one row per sleep session, natural key (deviceId, startTs).
            try db.create(table: "sleepSession") { t in
                t.column("deviceId", .text).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer).notNull()
                t.column("efficiency", .double)
                t.column("restingHr", .integer)
                t.column("avgHrv", .double)
                t.column("stagesJSON", .text)
                t.primaryKey(["deviceId", "startTs"])
            }
            // dailyMetric: one row per calendar day (YYYY-MM-DD), natural key (deviceId, day).
            try db.create(table: "dailyMetric") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("totalSleepMin", .double)
                t.column("efficiency", .double)
                t.column("deepMin", .double)
                t.column("remMin", .double)
                t.column("lightMin", .double)
                t.column("disturbances", .integer)
                t.column("restingHr", .integer)
                t.column("avgHrv", .double)
                t.column("recovery", .double)
                t.column("strain", .double)
                t.column("exerciseCount", .integer)
                t.primaryKey(["deviceId", "day"])
            }
        }
        migrator.registerMigration("v5") { db in
            // Per-row upload sync flag for the decoded streams. A forward-only highwater stranded backfilled
            // (older-ts) rows, so `synced` is set only after a successful upload and the Uploader drains WHERE synced=0.
            for table in ["hrSample", "rrInterval", "event", "battery",
                          "spo2Sample", "skinTempSample", "respSample", "gravitySample"] {
                try db.alter(table: table) { t in
                    t.add(column: "synced", .integer).notNull().defaults(to: 0)
                }
            }
        }
        migrator.registerMigration("v6") { db in
            // Charging flag for the BATTERY_LEVEL-event series (nullable: the command-response path doesn't report it).
            try db.alter(table: "battery") { t in
                t.add(column: "charging", .boolean)
            }
        }
        migrator.registerMigration("v7") { db in
            // In-sleep aggregates (SpO2, skin-temperature deviation, respiration rate), all nullable.
            try db.alter(table: "dailyMetric") { t in
                t.add(column: "spo2Pct", .double)
                t.add(column: "skinTempDevC", .double)
                t.add(column: "respRateBpm", .double)
            }
        }
        migrator.registerMigration("v8") { db in
            // Journal, workouts, and Apple-Health daily aggregates.
            // journal: one row per (deviceId, day, question).
            try db.create(table: "journal") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("question", .text).notNull()
                t.column("answeredYes", .integer).notNull()
                t.column("notes", .text)
                t.primaryKey(["deviceId", "day", "question"])
            }
            // workout: one row per (deviceId, startTs, sport). All metric columns nullable.
            try db.create(table: "workout") { t in
                t.column("deviceId", .text).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer).notNull()
                t.column("sport", .text).notNull()
                t.column("source", .text).notNull()
                t.column("durationS", .double)
                t.column("energyKcal", .double)
                t.column("avgHr", .integer)
                t.column("maxHr", .integer)
                t.column("strain", .double)
                t.column("distanceM", .double)
                t.column("zonesJSON", .text)
                t.column("notes", .text)
                t.primaryKey(["deviceId", "startTs", "sport"])
            }
            // appleDaily: one row per (deviceId, day). All metric columns nullable.
            try db.create(table: "appleDaily") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("steps", .integer)
                t.column("activeKcal", .double)
                t.column("basalKcal", .double)
                t.column("vo2max", .double)
                t.column("avgHr", .integer)
                t.column("maxHr", .integer)
                t.column("walkingHr", .integer)
                t.column("weightKg", .double)
                t.primaryKey(["deviceId", "day"])
            }
        }
        migrator.registerMigration("v9") { db in
            // Generic long-format metric store: one row per (deviceId, day, key) with a REAL `value`, so any scalar
            // metric can be read back by key with no per-metric schema.
            try db.create(table: "metricSeries") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("key", .text).notNull()
                t.column("value", .double).notNull()
                t.primaryKey(["deviceId", "day", "key"])
            }
            // The PK (deviceId, day, key) can't serve per-metric range reads; this index makes
            // metricSeries(key:from:to:) and metricDays(key:) index-only.
            try db.create(index: "idx_metricSeries_device_key_day",
                          on: "metricSeries", columns: ["deviceId", "key", "day"])
        }

        // v10: WHOOP5 step_motion_counter persistence. Additive only: the strap trims acked history and won't
        // re-send it, so a destructive rebuild would lose it. No `synced` column.
        migrator.registerMigration("v10") { db in
            try db.create(table: "stepSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("counter", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }

        // v11: on-device daily step total + whole-day calorie estimate on dailyMetric. Additive, both nullable.
        migrator.registerMigration("v11") { db in
            try db.alter(table: "dailyMetric") { t in
                t.add(column: "steps", .integer)
                t.add(column: "activeKcalEst", .double)
            }
        }

        // v12: PPG-derived per-second HR from the WHOOP 5.0 v26 optical buffer, in its OWN table so measured `hr`
        // is never conflated with the estimate (reads COALESCE hrSample first). Additive; conf is the 0-1 autocorrelation peak.
        migrator.registerMigration("v12") { db in
            try db.create(table: "ppgHrSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("bpm", .double).notNull()
                t.column("conf", .double).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }

        // v13: user-corrected sleep times. `userEdited` marks a session whose bounds the user fixed by hand so the
        // post-sync recompute preserves them. NOT NULL DEFAULT 0, so existing rows read as un-edited.
        migrator.registerMigration("v13") { db in
            try db.alter(table: "sleepSession") { t in
                t.add(column: "userEdited", .boolean).notNull().defaults(to: false)
            }
        }

        // v14: user-corrected sleep ONSET. `startTs` stays the immutable detected key; the hand-set bedtime lives
        // here. Nullable: null means "use startTs".
        migrator.registerMigration("v14") { db in
            try db.alter(table: "sleepSession") { t in
                t.add(column: "startTsAdjusted", .integer)
            }
        }

        // v15: the device registry. `deviceId` already keys every sample table; this adds a row per device with
        // brand/model/capabilities, a single-active invariant (enforced in DeviceRegistryStore), and a dayOwnership
        // override table so one source owns a day's scores (never blended). The existing WHOOP is seeded with its
        // unchanged id "my-whoop"; INSERT OR IGNORE keeps re-runs and restores safe.
        migrator.registerMigration("v15-device-registry") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pairedDevice (
                    id TEXT PRIMARY KEY NOT NULL,
                    brand TEXT NOT NULL, model TEXT NOT NULL, nickname TEXT,
                    sourceKind TEXT NOT NULL, capabilities TEXT NOT NULL,  -- comma-joined Metric rawValues
                    status TEXT NOT NULL, addedAt INTEGER NOT NULL, lastSeenAt INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS dayOwnership (
                    day TEXT PRIMARY KEY NOT NULL,   -- "YYYY-MM-DD" local day
                    deviceId TEXT NOT NULL,          -- which device owns this day's displayed/scored metrics
                    locked INTEGER NOT NULL DEFAULT 0 -- 1 = explicit (import-overlap decision / user); 0 = resolver default
                );
            """)
            // Seed a neutral "WHOOP" row; the app reconciles the model on first launch (the store can't read UserDefaults).
            let now = Int(Date().timeIntervalSince1970)
            try db.execute(sql: """
                INSERT OR IGNORE INTO pairedDevice (id, brand, model, nickname, sourceKind, capabilities, status, addedAt, lastSeenAt)
                VALUES ('my-whoop', 'WHOOP', 'WHOOP', NULL, 'liveBLE', 'hr,hrv,spo2,skinTemp,sleep,strainLoad', 'active', \(now), \(now));
            """)
        }

        // v16: stable per-strap identity for multi-WHOOP. `peripheralId` holds the CBPeripheral.identifier uuidString.
        // Additive + nullable: the seeded 'my-whoop' row keeps NULL; new straps get id "whoop-<peripheralId>".
        migrator.registerMigration("v16-paired-device-peripheral") { db in
            try db.execute(sql: "ALTER TABLE pairedDevice ADD COLUMN peripheralId TEXT")
        }

        // v17 (Lab Book): one row per dated reading the USER entered. Richer than the daily `metricSeries` projection:
        // a day can hold several readings, each with a precise `takenAt` and `unit`, and qualitative (`valueText`)
        // results don't fit a REAL cell. Additive, new table.
        //
        // NON-CLINICAL: only user-entered values plus an optional user-entered `referenceText`; no reference ranges.
        // `id` is client-generated; the natural key (deviceId, markerKey, takenAt, source) is UNIQUE so re-import is
        // idempotent. `value` is nullable; `day` is the pre-derived yyyy-MM-dd projection key.
        migrator.registerMigration("v17-lab-book") { db in
            try db.create(table: "labMarker") { t in
                t.column("id", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("markerKey", .text).notNull()
                t.column("category", .text).notNull()
                t.column("day", .text).notNull()              // yyyy-MM-dd (projection key)
                t.column("takenAt", .integer).notNull()       // epoch seconds (precise instant)
                t.column("value", .double)                    // nullable: qualitative entries use valueText
                t.column("valueText", .text)
                t.column("unit", .text).notNull()
                t.column("source", .text).notNull()
                t.column("note", .text)
                t.column("referenceText", .text)              // user-entered range, verbatim
            }
            // Idempotent re-import: one reading per (deviceId, markerKey, takenAt, source).
            try db.create(index: "idx_labMarker_natural",
                          on: "labMarker",
                          columns: ["deviceId", "markerKey", "takenAt", "source"],
                          unique: true)
            // Per-marker history reads.
            try db.create(index: "idx_labMarker_device_marker_takenAt",
                          on: "labMarker", columns: ["deviceId", "markerKey", "takenAt"])
            // Per-category grouping.
            try db.create(index: "idx_labMarker_device_category",
                          on: "labMarker", columns: ["deviceId", "category"])
        }

        // v18: per-sleep-session analytics the stager already computes, banked beside `stagesJSON` (deviceId, startTs):
        //   - `motionJSON`: per-epoch motion magnitudes, on the same 30 s grid as `stagesJSON`.
        //   - `sleepStateJSON`: the decoded v18 band state per epoch (`(sb>>4)&3`).
        // Both nullable TEXT; an absent signal stays null, never a fabricated zero series. Additive ALTERs only,
        // because the strap trims acked history and won't re-send it.
        migrator.registerMigration("v18-sleep-motion-state") { db in
            try db.alter(table: "sleepSession") { t in
                t.add(column: "motionJSON", .text)
                t.add(column: "sleepStateJSON", .text)
            }
        }

        // v19: nullable `stepSample.activityClass` (0=still, 1=walk, 2=run) from @63. Additive, no DEFAULT: null
        // means "no class for this record", never a fabricated 0/"still".
        migrator.registerMigration("v19-step-activity-class") { db in
            try db.alter(table: "stepSample") { t in
                t.add(column: "activityClass", .integer)
            }
        }

        // v20: nullable `journal.numericValue` (e.g. caffeine mg). No DEFAULT: null is a plain yes/no answer (every
        // existing and imported WHOOP row). A numeric log also writes answeredYes=1, so the with/without split is unchanged.
        migrator.registerMigration("v20-journal-numeric") { db in
            try db.alter(table: "journal") { t in
                t.add(column: "numericValue", .double)
            }
        }

        // v21: the strap's own per-record band sleep_state (@81 `(sb>>4)&3`: 0 wake / 1 still / 2 asleep / 3 up) as a
        // raw per-sample table keyed (deviceId, ts), upserted ON CONFLICT DO NOTHING. New table; forward-looking for
        // straps that emit it (5/MG v18). `state` is the raw 0-3 code verbatim.
        migrator.registerMigration("v21-sleep-state-sample") { db in
            try db.create(table: "sleepStateSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("state", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }

        // v22 (Live Sessions): one row per silent-guardian coaching session, natural key (deviceId, startTs). Records
        // the recovery-gated band, the time split, the cue counts and the HR source. `endTs` is nullable while in
        // progress (a crash leaves it open; the app closes it on next launch). Totals are NOT NULL DEFAULT 0.
        migrator.registerMigration("v22-live-session") { db in
            try db.create(table: "liveSession") { t in
                t.column("deviceId", .text).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer)
                t.column("chargeAtStart", .double)
                t.column("floorBpm", .double).notNull()
                t.column("ceilingBpm", .double).notNull()
                t.column("inBandSec", .double).notNull().defaults(to: 0)
                t.column("belowSec", .double).notNull().defaults(to: 0)
                t.column("aboveSec", .double).notNull().defaults(to: 0)
                t.column("pushCount", .integer).notNull().defaults(to: 0)
                t.column("easeCount", .integer).notNull().defaults(to: 0)
                t.column("hrSource", .text).notNull()
                t.primaryKey(["deviceId", "startTs"])
            }
        }
        migrator.registerMigration("v23-daily-spo2-raw") { db in
            // WHOOP 4.0 raw SpO2 PPG ADC means (red/IR) over detected sleep: two nullable INTEGER columns, additive.
            try db.alter(table: "dailyMetric") { t in
                t.add(column: "spo2Red", .integer)
                t.add(column: "spo2Ir", .integer)
            }
        }
        migrator.registerMigration("v24-rr-seq") { db in
            // Widen rrInterval's PK to (deviceId, ts, rrMs, seq). The old value-only key silently dropped the second of two
            // EQUAL successive R-R intervals in one second, biasing RMSSD high. `seq` distinguishes equal beats. SQLite
            // can't ALTER a PK, so rebuild: lossless (every row copied with seq = 0). Forward-only; rrInterval is a leaf
            // table (no FKs), so drop/rename is safe.
            try db.create(table: "rrInterval_new") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("rrMs", .integer).notNull()
                t.column("seq", .integer).notNull().defaults(to: 0)
                t.column("synced", .integer).notNull().defaults(to: 0)
                t.primaryKey(["deviceId", "ts", "rrMs", "seq"])
            }
            try db.execute(sql: """
                INSERT INTO rrInterval_new (deviceId, ts, rrMs, seq, synced)
                SELECT deviceId, ts, rrMs, 0, synced FROM rrInterval
                """)
            try db.execute(sql: "DROP TABLE rrInterval")
            try db.execute(sql: "ALTER TABLE rrInterval_new RENAME TO rrInterval")
        }

        // v25: lossless Oura live-API payload archive. One row per fetched page keyed (deviceId, endpoint, documentId);
        // payloadJSON is the verbatim body. Additive, new table.
        migrator.registerMigration("v25-oura-raw") { db in
            try db.create(table: "ouraRaw") { t in
                t.column("deviceId", .text).notNull()
                t.column("endpoint", .text).notNull()       // "sleep" | "daily_readiness" | "heartrate" | …
                t.column("documentId", .text).notNull()     // synthesized page key (endpoint + window + index)
                t.column("day", .text)                       // YYYY-MM-DD when day-keyed (nullable)
                t.column("payloadJSON", .text).notNull()     // verbatim page body
                t.column("fetchedAt", .integer).notNull()    // unix seconds
                t.primaryKey(["deviceId", "endpoint", "documentId"])
            }
            // Serves the (deviceId, endpoint) lookup, not the ORDER BY: `ouraRaw` sorts by (fetchedAt, rowid) because page
            // producers leave `day` nil. Add (deviceId, endpoint, fetchedAt) if that sort ever matters.
            try db.create(index: "idx_ouraRaw_device_endpoint_day",
                          on: "ouraRaw", columns: ["deviceId", "endpoint", "day"])
        }

        // v26 (Oura efficiency unit heal): the Oura API importer wrote native 0-100 `efficiency` into a column the
        // pipeline stores as a 0-1 FRACTION. UPDATE-only: divides by 100 where efficiency > 1.5, a threshold no genuine
        // fraction exceeds and no real percent-scale night falls under, so it is idempotent. Deliberately not
        // deviceId-scoped: both percent writers (Oura API importer, WHOOP CSV importer) are healed by the same predicate.
        migrator.registerMigration("v26-efficiency-heal") { db in
            try db.execute(sql: """
                UPDATE sleepSession SET efficiency = efficiency / 100.0
                WHERE efficiency > 1.5
                """)
            try db.execute(sql: """
                UPDATE dailyMetric SET efficiency = efficiency / 100.0
                WHERE efficiency > 1.5
                """)
        }

        // v27: durable storage for the WHOOP 5.0 v26 optical PPG waveform (24 Hz, 24 i16 ADC samples per record), which
        // was decoded but discarded after deriving `ppgHrSample` (v12). One row per (deviceId, ts), the 24 samples
        // packed into a BLOB (little-endian i16, `WhoopStore.packPpgSamples`/`unpackPpgSamples`). Additive, new table.
        //
        // Retention: capped at `WhoopStore.ppgWaveformRetentionRows` newest rows per device, swept amortised on insert
        // like `v18AuxSample`. It is the one per-second table that is pruned, because it stores a blob (~120 B/row vs
        // ~30 B). Newest-N rather than age-based, so a sporadic wearer is never emptied. `PrunePolicy`'s cap governs
        // only `rawBatch` and is unrelated.
        //
        // CONSUMER STATUS: deliberately none. The writer is live, but `ppgWaveformSamples` has no production callers
        // (tests only): unvalidated sensor work lands as instrumentation (decode + store, never a score) so a better
        // estimator or viewer can later run over the original samples. Do NOT remove the reader as dead code.
        // `ppgHrSample` (v12), by contrast, is the derived HR and is consumed; its derivation never reads this table.
        migrator.registerMigration("v27-ppg-waveform") { db in
            try db.create(table: "ppgWaveformSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("samples", .blob).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }

        // v28: WHOOP 5/MG raw-IMU offload capture (100 Hz 6-axis). `samples` is a packed i16 LE BLOB of the six wire
        // columns (ax..az, gx..gz); column order + PK match the Android `rawImuSample` table so a `.zoopbak` round-trips.
        // Historical rolling cache (max 3,600 one-second rows, never consumed); v41 retires it.
        migrator.registerMigration("v28-raw-imu") { db in
            try db.create(table: "rawImuSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("samples", .blob).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }

        // v29: provenance for Zoop-computed headline scores. Separate from `dayOwnership` (which device may supply a
        // day's raw inputs): this records which source supplied each persisted computed metric, keeping mixed-source
        // days honest.
        migrator.registerMigration("v29-score-input-provenance") { db in
            try db.create(table: "scoreInputProvenance") { t in
                t.column("deviceId", .text).notNull()   // computed "-zoop" namespace
                t.column("day", .text).notNull()
                t.column("key", .text).notNull()
                t.column("sourceId", .text).notNull()
                t.primaryKey(["deviceId", "day", "key"])
            }
            try db.create(index: "idx_scoreInputProvenance_source",
                          on: "scoreInputProvenance", columns: ["sourceId"])
        }

        // v30: record each R-R beat's EMISSION order within its second. Reads ordered by `rrMs` (value) make successive
        // beats similar by construction and bias RMSSD downward; `seq` can't help since every distinct beat has seq 0.
        //
        // Additive nullable column, deliberately NOT in the PK (an insertion counter there would collide distinct
        // beats arriving in separate batches); `ord` only informs read order. Pre-v30 rows stay NULL (never
        // recorded, so no backfill); NULL sorts first in ASC, so an all-NULL second falls back to (rrMs, seq).
        migrator.registerMigration("v30-rr-ord") { db in
            try db.alter(table: "rrInterval") { t in
                t.add(column: "ord", .integer)
            }
        }

        // v31: stop DISCARDING four per-second channels the 5/MG v18 decoder already produces. The drop was permanent
        // (the strap trims history once the offload is acked).
        //
        //   gravitySample.dynAccel    `dynamic_acceleration@41` (f32 g): the strap's own gravity-removed motion
        //                             magnitude, stored beside the incumbent `gravityDeltas` proxy.
        //   sleepStateSample.rawByte  the whole @81 flag byte (`state` is untouched; b6-7 uninterpreted).
        //   skinTempSample.aux1Raw    `temp_aux_1_raw@69` / `temp_aux_2_raw@71` (i16, C = value/10, a different scale
        //   skinTempSample.aux2Raw    from the primary's /100); track the primary closely.
        //
        // Additive nullable ALTERs, no DEFAULT: a WHOOP 4.0 never emits these and banked history can't be backfilled,
        // so an absent channel must stay NULL, never a fabricated 0.
        //
        // INSTRUMENTATION ONLY (see the "validate against the artifact" rule in CLAUDE.md): nothing reads these
        // columns or `v18AuxSamples` outside tests; data accrues now so a validated consumer is possible later. Do NOT
        // remove the readers as dead code.
        //
        // The remaining fifteen v18 slots are unpinned bytes whose names assert nothing, stored in their OWN narrow
        // table (see `V18AuxCodec`) because no existing per-second table is guaranteed present (each has its own
        // decode gate), because it keeps them out of tables analytics read, and because it can be reshaped freely.
        // `fields` is NOT NULL: a row is written only when at least one slot is present; absence is "no row" or a clear
        // bitmap bit, never a fabricated 0.
        //
        // Retention: `v18AuxSample` is capped at `WhoopStore.v18AuxRetentionRows` rows per device (rolling, newest-first)
        // and added to the storage-stats readout. The four columns add no rows and inherit their tables' retention.
        migrator.registerMigration("v31-deep-capture-channels") { db in
            try db.alter(table: "gravitySample") { t in
                t.add(column: "dynAccel", .double)
            }
            try db.alter(table: "sleepStateSample") { t in
                t.add(column: "rawByte", .integer)
            }
            try db.alter(table: "skinTempSample") { t in
                t.add(column: "aux1Raw", .integer)
                t.add(column: "aux2Raw", .integer)
            }
            try db.create(table: "v18AuxSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("fields", .blob).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }

        // v32: record WHICH sensor channel produced each R-R beat. An Oura ring reports the same heartbeats on more than
        // one tag, and all decoded to `OuraEvent.ibi` untagged (measured: 2.06x the beats the HR curve allows). That leaves
        // meanNN correct but collapses RMSSD/SDNN, which are built from successive differences.
        //
        // NOT a de-duplication: both rows are real measurements by different optics. Nothing is deleted; the column labels
        // the source and `Reads.rrIntervals` filters at READ. Additive nullable column, NOT in the PK (which stays
        // (deviceId, ts, rrMs, seq)): keying on it would let the same beat be inserted twice under two labels.
        //
        // Pre-v32 rows stay NULL and are still READ (a WHOOP row is legitimately NULL forever, so dropping NULL would
        // delete every WHOOP night from scoring). Historical Oura rows are not backfilled; they remain separable by
        // `rrMs % 8` (an 0x6E row is always a multiple of 8, an 0x80 row only 1 time in 8).
        //
        // Values are `RRSourceChannel.rawValue` (1 green / 2 spo2 / 3 ibiAmplitude), a durable wire format shared with
        // Kotlin `RrSourceChannel`. INTEGER, not text: `rrInterval` is the highest-volume table (~60k rows a night).
        migrator.registerMigration("v32-rr-src-channel") { db in
            try db.alter(table: "rrInterval") { t in
                t.add(column: "srcChannel", .integer)
            }
        }
        // v33: per-session step count on a workout, so a day's steps are recomputed as SUM over its sessions (additive
        // across files, idempotent on re-import). Nullable; only foot-sport activity-file sessions populate it.
        migrator.registerMigration("v33-workout-steps") { db in
            try db.alter(table: "workout") { t in
                t.add(column: "steps", .integer)
            }
        }
        // v34: per-session flag that a night was staged on SPARSE motion coverage (`SleepStager.isGravitySparse`), so the
        // Sleep tab can caption "sleep may be incomplete". Additive, nullable (null = unknown); not part of the PK.
        migrator.registerMigration("v34-sleep-staging-sparse") { db in
            // `.integer` (not `.boolean`) so the affinity is INTEGER on both platforms, as Room's Boolean? is. GRDB reads a Bool? as 0/1.
            try db.alter(table: "sleepSession") { t in
                t.add(column: "stagingSparse", .integer)
            }
        }
        // v35: quarantine R-R beats whose timestamp is in the FUTURE (a corrupt Oura history timestamp converted to a date
        // years ahead, so the beat was removed from its real night). The ingest gate now rejects such samples; this
        // takes already-stored rows out of scoring.
        //
        // NOT a delete: they are real heartbeats with a wrong timestamp, so the column MARKS them and `Reads.rrIntervals`
        // filters at READ, keeping them recoverable. `strftime('%s','now')` runs once at migration time; new rows are
        // gated at ingest and stay NULL. Additive nullable INTEGER, NOT in the PK.
        migrator.registerMigration("v35-rr-future-quarantine") { db in
            try db.alter(table: "rrInterval") { t in
                t.add(column: "tsSuspect", .integer)
            }
            // CAST so the compare is numeric: `strftime` returns TEXT.
            try db.execute(sql: "UPDATE rrInterval SET tsSuspect = 1 WHERE ts > CAST(strftime('%s','now') AS INTEGER)")
        }
        // v36: drop calibrated SpO2 from WHOOP registry capabilities (Zoop never fills spo2Pct from the strap, so an
        // advertised `spo2` made an empty tile look broken). Data-only UPDATE; the decode-time strip in DeviceRegistryStore is the belt.
        migrator.registerMigration("v36-whoop-caps-no-spo2") { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, capabilities FROM pairedDevice
                    WHERE brand = 'WHOOP' OR id = 'my-whoop' OR id LIKE 'whoop-%'
                    """
            )
            for row in rows {
                let id: String = row["id"]
                let encoded: String = row["capabilities"]
                let stripped = WhoopLiveCapabilities.stripSpo2Token(fromEncoded: encoded)
                if stripped != encoded && !stripped.isEmpty {
                    try db.execute(
                        sql: "UPDATE pairedDevice SET capabilities = ? WHERE id = ?",
                        arguments: [stripped, id]
                    )
                }
            }
        }

        // v37: persist nightly SDNN (the 5-min SDNN index from HRVAnalyzer.sdnnIndex, window-matched to a watch's short
        // SDNN rather than the drift-inflated whole-night SD). Additive, nullable.
        migrator.registerMigration("v37-daily-avg-sdnn") { db in
            try db.alter(table: "dailyMetric") { t in
                t.add(column: "avgSdnn", .double)
            }
        }
        // v38: hourly Apple Health step counts. The daily `appleDaily.steps` total hides which hours had no recording
        // (e.g. the phone died mid-hike). `ts` is the hour-bucket START (unix seconds, local-clock hour boundaries from
        // the `HKStatisticsCollectionQuery` anchored at local midnight); `steps` is the sum within that hour. PK
        // (deviceId, ts) makes the upsert idempotent. Additive, new table; a one-time backfill can answer past days.
        migrator.registerMigration("v38-apple-step-hour") { db in
            // ifNotExists: forks/sideloads that carry this table under another migration id converge instead of failing.
            try db.create(table: "appleStepHour", options: [.ifNotExists]) { t in
                t.column("deviceId", .text).notNull()   // "apple-health"
                t.column("ts", .integer).notNull()      // hour-start unix seconds (local-hour aligned by HK)
                t.column("steps", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }
        // v39: keep the v26 per-burst counter beside the waveform it segments. Existing rows stay nil (unrecoverable).
        migrator.registerMigration("v39-ppg-burst-index") { db in
            try db.alter(table: "ppgWaveformSample") { t in
                t.add(column: "burstIndex", .integer)
            }
        }
        // v40: keep the nightly ABSOLUTE skin temperature beside the deviation derived from it (a febrile night reads as
        // a small delta but a clear fever in absolute terms). Additive and nullable; nothing gates on it. Existing nights
        // refill on the next scoring pass from the raw `skinTempSample` rows still on disk.
        migrator.registerMigration("v40-daily-skin-temp-absolute") { db in
            try db.alter(table: "dailyMetric") { t in
                t.add(column: "skinTempC", .double)
            }
        }
        // Retire the bounded, write-only legacy cache; session-owned IMU now lives in the file-backed store.
        migrator.registerMigration("v41-drop-raw-imu-sample") { db in
            try db.drop(table: "rawImuSample")
        }
        // Whether every sleep session that day was staged from heart rate alone. Mirrors Android's `DailyMetric.sleepHrOnly`;
        // the shared schema oracle pins the two shapes together, so the column exists here even while only Android reads it.
        migrator.registerMigration("v42-daily-sleep-hr-only") { db in
            try db.alter(table: "dailyMetric") { t in
                t.add(column: "sleepHrOnly", .boolean)
            }
        }
        // v43: persist the Coach conversation on-device. One row per chat turn; `orderIndex` is a monotonic counter (not
        // `createdAt`, which streamed turns can share to the second) so replay order is exact. `provider` is carried for
        // a future per-provider view. Never added to the `.zoopbak` settings whitelist.
        migrator.registerMigration("v43-coach-messages") { db in
            try db.create(table: "coachMessage", options: [.ifNotExists]) { t in
                t.column("id", .text).primaryKey()
                t.column("role", .text).notNull()       // "user" | "assistant"
                t.column("text", .text).notNull()
                t.column("provider", .text).notNull()
                t.column("createdAt", .integer).notNull()
                t.column("orderIndex", .integer).notNull()
            }
            // No index: the table is capped at maxStoredMessages (40 rows).
        }
        // v44: carry the v26 optical window's ABSOLUTE base code beside its deltas (the window is one absolute ADC code
        // plus 24 deltas; only the deltas were stored, so the DC level was lost). Nullable and additive: existing rows get
        // a null base, which is the true statement, since a delta series can't be inverted without it.
        migrator.registerMigration("v44-ppg-waveform-base-code") { db in
            try db.alter(table: "ppgWaveformSample") { t in
                t.add(column: "baseCode", .integer)
            }
        }
        // v45: cover the cache witnesses of source promotions so non-WHOOP installs don't scan the whole R-R table per analysis tick.
        migrator.registerMigration("v45-rr-source-index") { db in
            try db.create(index: "rrInterval_source_suspect", on: "rrInterval", columns: ["srcChannel", "tsSuspect"])
        }
        // v46-lift-log: the in-app strength log, saved programs and the sessions run from them. Imports collapse a
        // workout to a session summary; these five tables hold the individual sets. A logged session still lands in
        // `workout` (Workouts / Today / Effort unchanged); these rows hang beside it.
        //
        // No load/strain column: `workout.strain` stays HR-measured and lifting volume is derived on read. Nothing here
        // feeds a score.
        //
        // Shape notes:
        //   - Five flat, deviceId-keyed tables joined by id (no foreign keys in this schema). Every table carries
        //     `deviceId` so `deleteAllData` (DeviceRegistryStore.deviceScopedTables) clears the whole feature.
        //   - `id` is a client-generated TEXT identifier (the labMarker idiom).
        //   - `liftSession` is keyed to its workout row by (deviceId, startTs, sport), UNIQUE.
        //   - Sets are ROWS, not a JSON blob, so "what did I lift for this exercise last time" is an index read.
        //   - Timestamps are unix seconds; booleans are `.integer` 0/1, never `.boolean` (GRDB's BOOLEAN is NUMERIC
        //     affinity, diverging from Room's INTEGER; see `grdb-boolean-affinity` in schema_oracle.json).
        //   - Every create is `ifNotExists` (tables and indexes) so a fork carrying these tables under another migration
        //     id converges instead of failing.
        //
        // Pinned in schema_oracle.json as `ios_only`; the Room twin is a follow-up.
        migrator.registerMigration("v46-lift-log") { db in
            // The user's own exercise vocabulary (no shipped catalogue), remembered on first use with the muscle group they
            // gave it so a per-muscle rollup is consistent.
            try db.create(table: "liftExercise", options: [.ifNotExists]) { t in
                t.column("id", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("name", .text).notNull()
                // Canonical LiftMuscle tokens, never free text. Nullable so an exercise can be recorded before it is classified.
                t.column("primaryMuscle", .text)
                // Comma-joined LiftMuscle tokens, or NULL.
                t.column("secondaryMuscles", .text)
                t.column("createdAt", .integer).notNull()   // unix seconds
                t.column("lastUsedTs", .integer)            // unix seconds; recency for the picker
            }
            // One entry per name per device, so recording a name twice updates rather than duplicates.
            try db.create(index: "idx_liftExercise_natural", on: "liftExercise",
                          columns: ["deviceId", "name"], options: [.unique, .ifNotExists])

            // A saved program ("Upper A"). Separate from the sessions run from it, so editing a program never rewrites history.
            try db.create(table: "liftProgram", options: [.ifNotExists]) { t in
                t.column("id", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("name", .text).notNull()
                t.column("note", .text)
                t.column("createdAt", .integer).notNull()   // unix seconds
                t.column("updatedAt", .integer).notNull()   // unix seconds; drives most-recent-first
                t.column("archived", .integer).notNull().defaults(to: 0)  // 0/1, hidden not deleted
            }
            // Programs list most-recently-touched first.
            try db.create(index: "idx_liftProgram_device_updatedAt",
                          on: "liftProgram", columns: ["deviceId", "updatedAt"], options: [.ifNotExists])

            // One exercise line in a program: the TARGETS. `ord` is the position; deliberately NOT unique with programId,
            // because reordering would collide mid-swap on a unique index.
            try db.create(table: "liftProgramItem", options: [.ifNotExists]) { t in
                t.column("id", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("programId", .text).notNull()
                t.column("ord", .integer).notNull()
                t.column("exercise", .text).notNull()
                // No muscle column: `liftExercise` owns classification.
                t.column("targetSets", .integer)
                t.column("targetRepsLow", .integer)        // rep range low end, e.g. 8 of "8-10"
                t.column("targetRepsHigh", .integer)       // rep range high end
                t.column("targetRpe", .double)             // 1-10, the user's own scale
                // Planned WEIGHT in kilograms, like every stored weight; display converts.
                t.column("targetWeightKg", .double)
                t.column("restSec", .integer)              // intended rest after each set
                t.column("note", .text)                    // the user's technique cue, verbatim
            }
            try db.create(index: "idx_liftProgramItem_device", on: "liftProgramItem",
                          columns: ["deviceId"], options: [.ifNotExists])
            try db.create(index: "idx_liftProgramItem_program_ord", on: "liftProgramItem",
                          columns: ["programId", "ord"], options: [.ifNotExists])

            // One gym session. (deviceId, startTs, sport) is the workout table's natural key, so this row and its `workout`
            // row identify each other without a foreign key. `programId` is nullable (freehand sessions).
            try db.create(table: "liftSession", options: [.ifNotExists]) { t in
                t.column("id", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("startTs", .integer).notNull()     // unix seconds; matches workout.startTs
                t.column("endTs", .integer)                 // nil while the session is still running
                t.column("sport", .text).notNull()          // matches workout.sport
                t.column("programId", .text)                // nil for a freehand session
                t.column("programName", .text)              // snapshot: renaming a program never rewrites history
                // 0-10 Borg CR10 rating; Foster's session load is sRPE x duration. Nullable: an unrated session has no load
                // (a 0 would read as "effortless").
                t.column("sessionRpe", .double)
                t.column("note", .text)
            }
            // One lift session per workout row; also serves date-ordered history reads.
            try db.create(index: "idx_liftSession_natural", on: "liftSession",
                          columns: ["deviceId", "startTs", "sport"], options: [.unique, .ifNotExists])

            // One set. `ord` is the position within the session; `setIndex` is 1-based within its exercise. `exercise` is
            // denormalised so a session stays readable after its program is edited or deleted.
            try db.create(table: "liftSet", options: [.ifNotExists]) { t in
                t.column("id", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("sessionId", .text).notNull()
                t.column("ord", .integer).notNull()          // order within the session
                t.column("exercise", .text).notNull()
                // The classification AS IT WAS when logged, so reclassifying an exercise doesn't silently rewrite past weeks.
                t.column("primaryMuscle", .text)
                t.column("secondaryMuscles", .text)
                t.column("setIndex", .integer).notNull()     // 1-based within the exercise
                t.column("weightKg", .double)                // kilograms; display units convert
                t.column("reps", .integer)
                t.column("rpe", .double)                     // 1-10 as rated by the user
                t.column("isWarmup", .integer).notNull().defaults(to: 0)  // 0/1; warmups excluded from volume
                t.column("startTs", .integer)                // when the set began (unix seconds)
                t.column("endTs", .integer)                  // when it ended
                t.column("restSec", .integer)                // rest ACTUALLY taken after this set
                t.column("note", .text)
            }
            // Last-time-for-this-exercise reads.
            try db.create(index: "idx_liftSet_device_exercise", on: "liftSet",
                          columns: ["deviceId", "exercise"], options: [.ifNotExists])
            // Replaying one session in order.
            try db.create(index: "idx_liftSet_session_ord", on: "liftSet",
                          columns: ["sessionId", "ord"], options: [.ifNotExists])
        }
        // v47: mark the WHOOP 5 500 ms fill beats already stored, with the rule `insert` applies to new batches
        // (`WhoopStore.whoop5RrFillFlagSQL`). Data only, a MARK in the v35 form, never a delete.
        migrator.registerMigration("v47-rr-whoop5-fill") { db in
            try db.execute(sql: WhoopStore.whoop5RrFillMigrationSQL)
        }
        // v48-fasting-session: user-logged fasting windows. Additive, one new table.
        //   - Not deviceId-keyed: a fast is the person's, so switching or deleting a strap must not take it along.
        //   - `endTs` NULL means running. At most one open row is an app-level rule (`FastingEngine.validate`), not a
        //     schema constraint, so a backdated edit can be validated as a whole.
        //   - `goalSec` is the goal when the fast started; `planId` is the `FastingPlan.id` it came from.
        //   - `source` ("app" | "shortcut") is for diagnostics only.
        // iOS-only: pinned in schema_oracle.json as `ios_only`, no Room twin.
        migrator.registerMigration("v48-fasting-session") { db in
            try db.create(table: "fastingSession", options: [.ifNotExists]) { t in
                t.column("id", .text).primaryKey()
                t.column("startTs", .integer).notNull()     // unix seconds
                t.column("endTs", .integer)                 // unix seconds; NULL while running
                t.column("goalSec", .integer).notNull()
                t.column("planId", .text).notNull()
                t.column("note", .text)
                t.column("source", .text).notNull()
            }
            try db.create(index: "idx_fastingSession_startTs", on: "fastingSession",
                          columns: ["startTs"], options: [.ifNotExists])
        }
        return migrator
    }
}
