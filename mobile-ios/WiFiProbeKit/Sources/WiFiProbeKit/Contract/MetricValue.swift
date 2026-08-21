import Foundation

/// A single entry in a record's `metrics` object.
///
/// The contract allows `number` or `string`: the probe uses strings for
/// `quality_tier` and the per-hop identity labels, numbers for everything
/// else. Modelling it as an enum makes an invalid metric unrepresentable
/// rather than caught later by the validator.
public enum MetricValue: Encodable, Equatable, Sendable {
    case number(Double)
    case string(String)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

extension MetricValue: ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension MetricValue {
    /// Rounded to two decimal places, as every probe workload rounds its
    /// output before returning it.
    public static func rounded(_ value: Double, places: Int = 2) -> MetricValue {
        let factor = pow(10.0, Double(places))
        return .number((value * factor).rounded() / factor)
    }
}
