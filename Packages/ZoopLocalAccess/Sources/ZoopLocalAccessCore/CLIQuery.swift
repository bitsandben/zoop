import Foundation

public struct ZoopCLIQueryRequest: Equatable, Sendable {
    public let toolName: String
    public let arguments: [String: JSONValue]
    public let configuration: LocalAccessConfiguration

    public init(
        toolName: String,
        arguments: [String: JSONValue],
        configuration: LocalAccessConfiguration = .environment()
    ) {
        self.toolName = toolName
        self.arguments = arguments
        self.configuration = configuration
    }
}

public enum ZoopCLIQueryError: Error, CustomStringConvertible, Equatable {
    case usage(String)

    public var description: String {
        switch self {
        case .usage(let message): return message
        }
    }

    public var exitCode: Int32 { 64 }
}

public enum ZoopCLIQuery {
    public static func parse(arguments: [String]) throws -> ZoopCLIQueryRequest {
        guard let toolName = arguments.first, !toolName.hasPrefix("-") else {
            throw ZoopCLIQueryError.usage("query requires one tool name")
        }
        guard ZoopToolDispatcher.toolNames.contains(toolName) else {
            throw ZoopCLIQueryError.usage("unknown query tool")
        }

        var toolArguments: [String: JSONValue] = [:]
        var configuration = LocalAccessConfiguration.environment()
        var seenFlags = Set<String>()
        var index = 1

        while index < arguments.count {
            let flag = arguments[index]
            guard flag.hasPrefix("--") else {
                throw ZoopCLIQueryError.usage("query does not accept additional positional arguments")
            }
            guard seenFlags.insert(flag).inserted else {
                throw ZoopCLIQueryError.usage("duplicate query flag: \(flag)")
            }
            index += 1

            switch flag {
            case "--db-path":
                configuration.databasePath = try requiredValue(flag, arguments: arguments, index: &index)
            case "--days":
                guard toolName != "data_freshness" else { throw unsupported(flag, toolName: toolName) }
                toolArguments["days"] = try integerValue(flag, arguments: arguments, index: &index)
            case "--key":
                guard toolName == "metric_series" else { throw unsupported(flag, toolName: toolName) }
                toolArguments["key"] = .string(try requiredValue(flag, arguments: arguments, index: &index))
            case "--source":
                guard toolName == "metric_series" else { throw unsupported(flag, toolName: toolName) }
                toolArguments["source"] = .string(try requiredValue(flag, arguments: arguments, index: &index))
            case "--from-day":
                guard toolName == "metric_series" else { throw unsupported(flag, toolName: toolName) }
                toolArguments["from_day"] = .string(try requiredValue(flag, arguments: arguments, index: &index))
            case "--to-day":
                guard toolName == "metric_series" else { throw unsupported(flag, toolName: toolName) }
                toolArguments["to_day"] = .string(try requiredValue(flag, arguments: arguments, index: &index))
            case "--limit":
                guard toolName == "metric_series" else { throw unsupported(flag, toolName: toolName) }
                toolArguments["limit"] = try integerValue(flag, arguments: arguments, index: &index)
            default:
                throw ZoopCLIQueryError.usage("unknown query flag")
            }
        }

        if toolName == "metric_series", toolArguments["key"] == nil {
            throw ZoopCLIQueryError.usage("metric_series requires --key")
        }

        return ZoopCLIQueryRequest(toolName: toolName, arguments: toolArguments, configuration: configuration)
    }

    public static func dispatch(_ request: ZoopCLIQueryRequest) throws -> JSONValue {
        try ZoopToolDispatcher(configuration: request.configuration)
            .dispatch(name: request.toolName, arguments: request.arguments)
    }

    public static func encodeLine(_ value: JSONValue) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    private static func requiredValue(_ flag: String, arguments: [String], index: inout Int) throws -> String {
        guard index < arguments.count, !arguments[index].hasPrefix("--") else {
            throw ZoopCLIQueryError.usage("missing value for \(flag)")
        }
        defer { index += 1 }
        return arguments[index]
    }

    private static func integerValue(_ flag: String, arguments: [String], index: inout Int) throws -> JSONValue {
        let raw = try requiredValue(flag, arguments: arguments, index: &index)
        guard let value = Int(raw) else {
            throw ZoopCLIQueryError.usage("value for \(flag) must be an integer")
        }
        return .int(value)
    }

    private static func unsupported(_ flag: String, toolName: String) -> ZoopCLIQueryError {
        .usage("\(flag) is not supported for \(toolName)")
    }
}
