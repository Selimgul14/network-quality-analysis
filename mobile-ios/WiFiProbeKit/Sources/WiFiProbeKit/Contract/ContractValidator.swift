import Foundation

public enum ContractError: Error, Equatable, Sendable {
    case missingKey(String)
    case unexpectedKey(String)
    case badValue(key: String, reason: String)
}

/// Checks a record against `contracts/measurement.schema.json` before it is
/// posted (M3).
///
/// The schema is read-only (C8) and lives in the other repo, so it cannot
/// be loaded and applied directly. This is a hand-written equivalent of the
/// parts that can actually go wrong from this client, and it exists so a
/// 422 from the backend is impossible rather than merely unlikely. A
/// failure here is an app bug, not a network condition, and is surfaced as
/// such.
public enum ContractValidator {

    /// `required` in the schema.
    public static let requiredKeys = [
        "ts", "probe_id", "run_id", "workload", "endpoint", "target", "ok", "metrics",
    ]

    /// `properties` in the schema, which sets `additionalProperties: false`.
    public static let allowedKeys = requiredKeys + [
        "site", "error", "context", "raw_ref", "net_hash",
    ]

    private static let nullableStrings = ["site", "error", "raw_ref", "net_hash"]

    public static func validate(_ json: [String: Any]) throws {
        for key in json.keys where !allowedKeys.contains(key) {
            throw ContractError.unexpectedKey(key)
        }
        for key in requiredKeys {
            guard let value = json[key], !(value is NSNull) else {
                throw ContractError.missingKey(key)
            }
        }

        try validateTimestamp(json["ts"])
        for key in ["probe_id", "run_id", "target"] {
            try validateNonEmptyString(json[key], key: key)
        }
        try validateEnum(json["workload"], key: "workload",
                         allowed: Workload.allCases.map(\.rawValue))
        try validateEnum(json["endpoint"], key: "endpoint",
                         allowed: Endpoint.allCases.map(\.rawValue))

        guard isBoolean(json["ok"]) else {
            throw ContractError.badValue(key: "ok", reason: "not a boolean")
        }
        try validateMetrics(json["metrics"])

        for key in nullableStrings {
            guard let value = json[key], !(value is NSNull) else { continue }
            guard value is String else {
                throw ContractError.badValue(key: key, reason: "not a string or null")
            }
        }
        if let context = json["context"], !(context is NSNull),
           !(context is [String: Any]) {
            throw ContractError.badValue(key: "context", reason: "not an object or null")
        }
    }

    // MARK: helpers

    private static func validateTimestamp(_ value: Any?) throws {
        guard let text = value as? String else {
            throw ContractError.badValue(key: "ts", reason: "not a string")
        }
        guard Record.timestampFormatter.date(from: text) != nil else {
            throw ContractError.badValue(key: "ts", reason: "not ISO 8601 with a timezone")
        }
    }

    private static func validateNonEmptyString(_ value: Any?, key: String) throws {
        guard let text = value as? String else {
            throw ContractError.badValue(key: key, reason: "not a string")
        }
        guard !text.isEmpty else {
            throw ContractError.badValue(key: key, reason: "empty")
        }
    }

    private static func validateEnum(_ value: Any?, key: String, allowed: [String]) throws {
        try validateNonEmptyString(value, key: key)
        guard let text = value as? String, allowed.contains(text) else {
            throw ContractError.badValue(key: key, reason: "not one of \(allowed)")
        }
    }

    /// `metrics` maps names to numbers or strings, and nothing else.
    private static func validateMetrics(_ value: Any?) throws {
        guard let metrics = value as? [String: Any] else {
            throw ContractError.badValue(key: "metrics", reason: "not an object")
        }
        for (name, entry) in metrics {
            if entry is String { continue }
            // A JSON boolean also bridges to NSNumber, so it has to be
            // excluded explicitly or `true` would pass as a number.
            if entry is NSNumber, !isBoolean(entry) { continue }
            throw ContractError.badValue(key: "metrics.\(name)",
                                         reason: "not a number or string")
        }
    }

    private static func isBoolean(_ value: Any?) -> Bool {
        guard let value else { return false }
        return CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }
}
