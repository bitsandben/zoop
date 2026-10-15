import Foundation

// MARK: - Coloured route copy (zoop.route.* catalogue entries)
//
// Resolved against the app catalogue (Strand/Resources/Localizable.xcstrings) at the point of use, so the
// app-language override applies; tests and previews fall back to the English default.

enum RouteStrings {

    static var title: String { String(localized: "zoop.route.title", defaultValue: "Route", bundle: .main) }
    static var pace: String { String(localized: "zoop.route.metric.pace", defaultValue: "Pace", bundle: .main) }
    static var speed: String { String(localized: "zoop.route.metric.speed", defaultValue: "Speed", bundle: .main) }
    static var heartRate: String { String(localized: "zoop.route.metric.heartRate", defaultValue: "Heart rate", bundle: .main) }
    static var altitude: String { String(localized: "zoop.route.metric.altitude", defaultValue: "Elevation", bundle: .main) }

    static var paceCaption: String {
        String(localized: "zoop.route.caption.pace",
               defaultValue: "Colours compare this workout with itself; the fastest and slowest 5% are capped.", bundle: .main)
    }
    static var heartRateCaption: String {
        String(localized: "zoop.route.caption.heartRate", defaultValue: "Colours show your heart-rate zones along the route.", bundle: .main)
    }
    static var altitudeCaption: String {
        String(localized: "zoop.route.caption.altitude", defaultValue: "Colours run from the lowest to the highest point of this route.", bundle: .main)
    }
    static var pausedNote: String {
        String(localized: "zoop.route.caption.paused", defaultValue: "Grey marks pauses and stops.", bundle: .main)
    }

    static var start: String { String(localized: "zoop.route.start", defaultValue: "Start", bundle: .main) }
    static var finish: String { String(localized: "zoop.route.finish", defaultValue: "Finish", bundle: .main) }
    static var expand: String { String(localized: "zoop.route.expand", defaultValue: "Show full map", bundle: .main) }
    static var close: String { String(localized: "zoop.route.close", defaultValue: "Close", bundle: .main) }
    static var mapStandard: String { String(localized: "zoop.route.map.standard", defaultValue: "Map", bundle: .main) }
    static var mapSatellite: String { String(localized: "zoop.route.map.satellite", defaultValue: "Satellite", bundle: .main) }
    static var scrubHint: String {
        String(localized: "zoop.route.chart.hint", defaultValue: "Drag along the chart to find the spot on the map.", bundle: .main)
    }

    // Splits table
    static var splitsTitle: String { String(localized: "zoop.route.splits.title", defaultValue: "Splits", bundle: .main) }
    static var splitTime: String { String(localized: "zoop.route.splits.time", defaultValue: "Time", bundle: .main) }
    static var splitHR: String { String(localized: "zoop.route.splits.hr", defaultValue: "Avg HR", bundle: .main) }
    static var splitClimb: String { String(localized: "zoop.route.splits.climb", defaultValue: "Climb", bundle: .main) }

    static func mapAccessibility(sport: String, distance: String) -> String {
        String(localized: "zoop.route.map.a11y", defaultValue: "Map of your \(sport) route, \(distance).", bundle: .main)
    }

    // My routes (heat map)
    static var heatTitle: String { String(localized: "zoop.route.heat.title", defaultValue: "My routes", bundle: .main) }
    static func heatSubtitle(_ count: Int) -> String {
        String(localized: "zoop.route.heat.subtitle", defaultValue: "\(count) GPS routes in the last 90 days", bundle: .main)
    }
    static var heatCaption: String {
        String(localized: "zoop.route.heat.caption", defaultValue: "The more often you ran a stretch, the stronger its line.", bundle: .main)
    }
}
