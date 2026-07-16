import Foundation

public enum PersonalVPNError: Error, LocalizedError, Equatable {
    case invalidConfiguration(String)
    case invalidSubscription(String)
    case unsupportedProtocol(String)
    case safetyGateDenied(String)
    case engineFailure(String)
    case apiFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let value): "Invalid configuration: \(value)"
        case .invalidSubscription(let value): "Invalid subscription: \(value)"
        case .unsupportedProtocol(let value): "Unsupported protocol: \(value)"
        case .safetyGateDenied(let value): "Safety gate denied: \(value)"
        case .engineFailure(let value): "Engine failure: \(value)"
        case .apiFailure(let value): "API failure: \(value)"
        }
    }
}
