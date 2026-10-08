import Foundation

/// The single read-only dispatch surface shared by MCP and the direct CLI transport.
public final class ZoopToolDispatcher {
    private let configuration: LocalAccessConfiguration
    private var dataAccess: ZoopDataAccess?

    public init(configuration: LocalAccessConfiguration = .environment()) {
        self.configuration = configuration
    }

    public static let toolNames = [
        "health_snapshot",
        "metric_series",
        "data_freshness",
        "sleep_summary",
        "workout_summary",
    ]

    public func dispatch(name: String, arguments: [String: JSONValue] = [:]) throws -> JSONValue {
        switch name {
        case "health_snapshot":
            return try data().healthSnapshot(days: boundedDays(arguments["days"], default: 14, max: 120))
        case "metric_series":
            guard let key = arguments["key"]?.stringValue else {
                throw LocalAccessError.invalidParams("metric_series requires key")
            }
            return try data().metricSeries(
                key: key,
                source: arguments["source"]?.stringValue ?? "my-whoop",
                days: boundedDays(arguments["days"], default: 90, max: 4000),
                fromDay: arguments["from_day"]?.stringValue,
                toDay: arguments["to_day"]?.stringValue,
                limit: boundedLimit(arguments["limit"], default: 500, max: 2000)
            )
        case "data_freshness":
            return try data().freshness()
        case "sleep_summary":
            return try data().sleepSummary(days: boundedDays(arguments["days"], default: 30, max: 4000))
        case "workout_summary":
            return try data().workoutSummary(days: boundedDays(arguments["days"], default: 90, max: 4000))
        default:
            throw LocalAccessError.toolNotFound(name)
        }
    }

    public func resourcePayload(uri: String) throws -> JSONValue {
        switch uri {
        case "zoop://health/snapshot":
            return try dispatch(name: "health_snapshot", arguments: ["days": .int(14)])
        case "zoop://data/freshness":
            return try dispatch(name: "data_freshness")
        case "zoop://metrics/catalog":
            return ZoopDataAccess.metricCatalog()
        case "zoop://sources":
            return ZoopDataAccess.sources()
        default:
            throw LocalAccessError.resourceNotFound(uri)
        }
    }

    private func data() throws -> ZoopDataAccess {
        if let dataAccess { return dataAccess }
        do {
            let access = try ZoopDataAccess.open(configuration: configuration)
            dataAccess = access
            return access
        } catch let error as LocalAccessError {
            throw error
        } catch {
            throw LocalAccessError.databaseUnavailable("Zoop database is not available: \(error)")
        }
    }
}
