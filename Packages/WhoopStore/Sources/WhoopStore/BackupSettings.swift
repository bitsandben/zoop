import Foundation

/// The `settings.json` payload inside a `.zoopbak` backup: a flat JSON object carrying a WHITELISTED set
/// of profile and display preferences that live in UserDefaults and would otherwise reset on restore.
///
/// The whitelist is a byte-identical contract with Android's `BackupSettingsCodec` (same canonical keys,
/// same JSON kinds). NEVER add device ids, peripheral ids, tokens, sync cursors or anything
/// anonymity-sensitive: backups get shared. Unknown keys on decode are dropped; a backup with no
/// `settings.json` is a DB-only restore. No ZIP code here (that lives in the app's `DataBackup`).
public enum BackupSettings {

    /// Canonical entry name inside the `.zoopbak` ZIP.
    public static let entryName = "settings.json"

    /// The JSON kind a whitelisted key must decode to. Anything else is dropped rather than guessed at.
    public enum Kind: Sendable {
        case int, double, string
    }

    /// THE whitelist: the only keys `settings.json` may carry, by canonical (platform-neutral) name.
    /// Mirrored exactly by Android's `BackupSettingsCodec.WHITELIST`.
    ///
    /// Profile (body metrics, `profile.hrMax` with 0 = auto/Tanaka) and display systems are included.
    /// Excluded: per-strap step calibration, the avatar blob, derived steps-engine outputs, and every
    /// device- or install-specific `zoop.*` toggle (section order, Key-Metrics and dashboard-card selections).
    ///
    /// `today.hostedCards` is the one layout pref carried (a JSON `[String]` on the String kind); the section's
    /// position is not, so it returns at its default slot.
    public static let whitelist: [String: Kind] = [
        "profile.age": .int,
        "profile.sex": .string,
        "profile.weightKg": .double,
        "profile.heightCm": .double,
        "profile.waistCm": .double,
        "profile.hrMax": .int,
        "profile.hrZoneThresholds": .string,
        "units.system": .string,
        "units.distance": .string,
        "units.temperature": .string,
        "effort.scale": .string,
        "dayCycle.mode": .string,
        "today.hostedCards": .string,
        // The user's custom journal behaviours (newline-joined names). Not in `appleDefaultsKey` because it is
        // derived from the catalog items blob; `DataBackup` bridges it. Names only: a numeric custom behaviour
        // restores as a plain .bool toggle on both platforms.
        "journal.customBehaviors": .string,
    ]

    /// Canonical JSON key to this platform's UserDefaults key. Identity except `profile.hrMax`, which is
    /// stored as `profile.hrMaxOverride` (see `ProfileStore.K`).
    public static let appleDefaultsKey: [String: String] = [
        "profile.age": "profile.age",
        "profile.sex": "profile.sex",
        "profile.weightKg": "profile.weightKg",
        "profile.heightCm": "profile.heightCm",
        "profile.waistCm": "profile.waistCm",
        "profile.hrMax": "profile.hrMaxOverride",
        "profile.hrZoneThresholds": "profile.hrZoneThresholds",
        "units.system": "units.system",
        "units.distance": "units.distance",
        "units.temperature": "units.temperature",
        "effort.scale": "effort.scale",
        "dayCycle.mode": "zoop.dayCycleMode",
        "today.hostedCards": "today.hostedCards",
    ]

    // MARK: - Snapshot / apply (UserDefaults boundary)

    /// The whitelisted values currently SET in `defaults`, keyed canonically. Untouched keys are omitted,
    /// so a restore only overwrites what was genuinely set.
    public static func snapshot(from defaults: UserDefaults) -> [String: Any] {
        var out: [String: Any] = [:]
        for (canonical, kind) in whitelist {
            guard let storageKey = appleDefaultsKey[canonical],
                  let raw = defaults.object(forKey: storageKey),
                  let coerced = coerce(raw, to: kind) else { continue }
            out[canonical] = coerced
        }
        return out
    }

    /// Writes whitelisted `values` (canonical keys) into `defaults`; non-whitelisted keys and wrong-typed
    /// values are ignored. Call only after a successful DB swap.
    public static func apply(_ values: [String: Any], to defaults: UserDefaults) {
        for (canonical, kind) in whitelist {
            guard let raw = values[canonical],
                  let coerced = coerce(raw, to: kind),
                  let storageKey = appleDefaultsKey[canonical] else { continue }
            defaults.set(coerced, forKey: storageKey)
        }
        // The whitelist carries an Int age, not a date: clear any stale `profile.dateOfBirth` so `ProfileStore`
        // re-derives it from the restored age on relaunch instead of a local DOB overriding the restore.
        if values["profile.age"] != nil {
            defaults.removeObject(forKey: dobDefaultsKey)
        }
    }

    /// UserDefaults key `ProfileStore` stores the date of birth under. Not whitelisted; only cleared on restore.
    /// Must match `ProfileStore.K.dateOfBirth`.
    static let dobDefaultsKey = "profile.dateOfBirth"

    // MARK: - JSON codec

    /// Encodes the whitelisted subset of `values` as the flat `settings.json` object, deterministically
    /// (`.sortedKeys`). Returns nil when nothing whitelisted is present (DB-only backup).
    public static func encode(_ values: [String: Any]) -> Data? {
        var filtered: [String: Any] = [:]
        for (key, kind) in whitelist {
            guard let raw = values[key], let coerced = coerce(raw, to: kind) else { continue }
            filtered[key] = coerced
        }
        guard !filtered.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: filtered, options: [.sortedKeys])
    }

    /// Decodes a `settings.json` payload to its whitelisted, correctly-typed subset. Bad input degrades to
    /// fewer keys, never an error, so it cannot fail a restore whose DB half is fine.
    public static func decode(_ data: Data) -> [String: Any] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var out: [String: Any] = [:]
        for (key, kind) in whitelist {
            guard let raw = obj[key], let coerced = coerce(raw, to: kind) else { continue }
            out[key] = coerced
        }
        return out
    }

    // MARK: - Coercion

    /// Coerces a decoded value to the declared kind, or nil. JSON booleans are `NSNumber` too, so they are
    /// refused for numeric kinds (`true` must never become age 1).
    private static func coerce(_ value: Any, to kind: Kind) -> Any? {
        switch kind {
        case .string:
            return value as? String
        case .int:
            guard let n = value as? NSNumber, !isBoolean(n) else { return nil }
            return n.intValue
        case .double:
            guard let n = value as? NSNumber, !isBoolean(n) else { return nil }
            return n.doubleValue
        }
    }

    private static func isBoolean(_ n: NSNumber) -> Bool {
#if canImport(Darwin)
        CFGetTypeID(n) == CFBooleanGetTypeID()
#else
        // corelibs Foundation boxes JSON booleans with the Objective-C `c` type encoding.
        String(cString: n.objCType) == "c"
#endif
    }
}
