import Foundation

/// The named-sport catalogue for the workout pickers (manual add/edit and live tracking): the display
/// name plus whether a route makes sense (drives the "· GPS" hint and GPS default). Names are DATA, not
/// UI literals: `WorkoutRow.sport` is persisted verbatim (and round-trips through CSV / Apple Health
/// export), so they must never be localised. Free text stays allowed; this is the suggestion set, not a
/// whitelist (#519).
enum WorkoutCatalog {

    /// One selectable activity. `name` is the verbatim stored/display label.
    struct Sport: Identifiable, Hashable {
        let name: String
        /// Types where a route makes sense (GPS hint and default on).
        let isDistanceSport: Bool
        var id: String { name }
    }

    /// Common / distance sports first, then the rest, then the generic "Other" last.
    static let all: [Sport] = [
        Sport(name: "Running", isDistanceSport: true),
        Sport(name: "Walking", isDistanceSport: true),
        Sport(name: "Hiking", isDistanceSport: true),
        Sport(name: "Cycling", isDistanceSport: true),
        Sport(name: "Open-water swim", isDistanceSport: true),
        Sport(name: "Rowing", isDistanceSport: true),
        Sport(name: "Treadmill run", isDistanceSport: false),
        // Indoor treadmill walk (#714); GPS off like Treadmill run.
        Sport(name: "Treadmill walk", isDistanceSport: false),
        Sport(name: "Indoor cycle", isDistanceSport: false),
        Sport(name: "Pool swim", isDistanceSport: false),
        Sport(name: "Row machine", isDistanceSport: false),
        Sport(name: "Elliptical", isDistanceSport: false),
        Sport(name: "Strength", isDistanceSport: false),
        // Strength-style session, no route (#714).
        Sport(name: "Bodybuilding", isDistanceSport: false),
        Sport(name: "Weightlifting", isDistanceSport: false),
        Sport(name: "HIIT", isDistanceSport: false),
        Sport(name: "Yoga", isDistanceSport: false),
        Sport(name: "Pilates", isDistanceSport: false),
        Sport(name: "Boxing", isDistanceSport: false),
        Sport(name: "Basketball", isDistanceSport: false),
        Sport(name: "Soccer", isDistanceSport: false),
        Sport(name: "Baseball", isDistanceSport: false),
        Sport(name: "Badminton", isDistanceSport: false),
        Sport(name: "Tennis", isDistanceSport: false),
        Sport(name: "Squash", isDistanceSport: false),
        Sport(name: "Racquetball", isDistanceSport: false),
        Sport(name: "Table tennis", isDistanceSport: false),
        Sport(name: "Volleyball", isDistanceSport: false),
        // Covers Jiu-Jitsu, karate, judo, MMA etc. (#768)
        Sport(name: "Martial arts", isDistanceSport: false),
        Sport(name: "Dancing", isDistanceSport: false),
        Sport(name: "Golf", isDistanceSport: false),
        Sport(name: "Climbing", isDistanceSport: false),
        Sport(name: "Stretching", isDistanceSport: false),
        // Snow sports cover ground, so GPS defaults on (#768).
        Sport(name: "Skiing", isDistanceSport: true),
        Sport(name: "Snowboarding", isDistanceSport: true),
        Sport(name: "Padel", isDistanceSport: false),
        Sport(name: "Pickleball", isDistanceSport: false),
        // Light lane sport, no route.
        Sport(name: "Bowling", isDistanceSport: false),
        // Only the native distance sports (paddling/sailing/skating/snowshoeing) default GPS on.
        Sport(name: "Ice Hockey", isDistanceSport: false),
        Sport(name: "American football", isDistanceSport: false),
        Sport(name: "Australian football", isDistanceSport: false),
        Sport(name: "Rugby", isDistanceSport: false),
        Sport(name: "Cricket", isDistanceSport: false),
        Sport(name: "Softball", isDistanceSport: false),
        Sport(name: "Handball", isDistanceSport: false),
        Sport(name: "Water polo", isDistanceSport: false),
        Sport(name: "Frisbee", isDistanceSport: false),
        Sport(name: "Surfing", isDistanceSport: false),
        Sport(name: "Kayaking", isDistanceSport: true),
        Sport(name: "Sailing", isDistanceSport: true),
        Sport(name: "Scuba diving", isDistanceSport: false),
        Sport(name: "Ice skating", isDistanceSport: false),
        Sport(name: "Inline skating", isDistanceSport: true),
        Sport(name: "Snowshoeing", isDistanceSport: true),
        Sport(name: "Gymnastics", isDistanceSport: false),
        Sport(name: "Fencing", isDistanceSport: false),
        Sport(name: "Calisthenics", isDistanceSport: false),
        Sport(name: "Stair climber", isDistanceSport: false),
        Sport(name: "Boot camp", isDistanceSport: false),
        Sport(name: "Lacrosse", isDistanceSport: false),
        Sport(name: "Field hockey", isDistanceSport: false),
        Sport(name: "CrossFit", isDistanceSport: false),
        Sport(name: "Kickboxing", isDistanceSport: false),
        Sport(name: "Mountain biking", isDistanceSport: false),
        Sport(name: "Skateboarding", isDistanceSport: false),
        Sport(name: "Stand-up paddleboard", isDistanceSport: false),
        Sport(name: "Spinning", isDistanceSport: false),
        Sport(name: "Jump rope", isDistanceSport: false),
        Sport(name: "Powerlifting", isDistanceSport: false),
        // Long-tail batch; GPS off.
        Sport(name: "Rucking", isDistanceSport: false),
        Sport(name: "Sand volleyball", isDistanceSport: false),
        Sport(name: "Archery", isDistanceSport: false),
        Sport(name: "Fishing", isDistanceSport: false),
        Sport(name: "Hunting", isDistanceSport: false),
        Sport(name: "Curling", isDistanceSport: false),
        Sport(name: "Netball", isDistanceSport: false),
        Sport(name: "Gaelic football", isDistanceSport: false),
        Sport(name: "Spikeball", isDistanceSport: false),
        // GPS defaults off for all of these extras.
        Sport(name: "Meditation", isDistanceSport: false),
        Sport(name: "Horseback riding", isDistanceSport: false),
        Sport(name: "Wheelchair", isDistanceSport: false),
        Sport(name: "Gaming", isDistanceSport: false),
        Sport(name: "Motor racing", isDistanceSport: false),
        // GPS stays off for every extra sport regardless of route (Mountain biking and Rucking likewise);
        // revisit them together.
        Sport(name: "Nordic walking", isDistanceSport: false),
        Sport(name: "Ballet", isDistanceSport: false),
        Sport(name: "Billiards", isDistanceSport: false),
        Sport(name: "Breakdancing", isDistanceSport: false),
        Sport(name: "Cheerleading", isDistanceSport: false),
        Sport(name: "Darts", isDistanceSport: false),
        Sport(name: "Disc golf", isDistanceSport: false),
        Sport(name: "Hurling/Camogie", isDistanceSport: false),
        Sport(name: "Jiu jitsu", isDistanceSport: false),
        Sport(name: "Judo", isDistanceSport: false),
        Sport(name: "Kiteboarding", isDistanceSport: false),
        Sport(name: "Motocross", isDistanceSport: false),
        Sport(name: "Muay Thai", isDistanceSport: false),
        Sport(name: "Paintball", isDistanceSport: false),
        Sport(name: "Parkour", isDistanceSport: false),
        Sport(name: "Polo", isDistanceSport: false),
        Sport(name: "Skydiving", isDistanceSport: false),
        Sport(name: "Other", isDistanceSport: false),
    ]

    /// The default sport for a manual-start live workout (the auto-detector relabels detected bouts).
    static let defaultSportName = "Other"

    /// Case-insensitive lookup of the suggestion matching a possibly free-typed label; nil for an
    /// off-catalogue sport, which is still valid.
    static func sport(named name: String) -> Sport? {
        let q = name.trimmingCharacters(in: .whitespaces)
        return all.first { $0.name.caseInsensitiveCompare(q) == .orderedSame }
    }

    /// Catalogue filtered by a case-insensitive name query (empty returns the whole list).
    static func matching(_ query: String) -> [Sport] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.range(of: q, options: .caseInsensitive) != nil }
    }

    /// Sports where a step count is meaningful (#398): outdoor and treadmill run/walk and hiking, not
    /// cycling, rowing, swimming or gym/court sports where a step tally would be noise.
    static let onFootSportNames: Set<String> = [
        "Running", "Walking", "Hiking", "Treadmill run", "Treadmill walk",
    ]

    /// Whether `sportName` (possibly free-typed) is an on-foot sport that should show steps. Case-insensitive, trimmed.
    static func isOnFoot(_ sportName: String) -> Bool {
        let q = sportName.trimmingCharacters(in: .whitespaces)
        return onFootSportNames.contains { $0.caseInsensitiveCompare(q) == .orderedSame }
    }
}
