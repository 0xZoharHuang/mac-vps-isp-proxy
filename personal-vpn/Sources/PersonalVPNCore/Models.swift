import Foundation

public enum VPNMode: String, Codable, Sendable, CaseIterable {
    case direct
    case stable
    case subscription
}

public enum ConnectionPhase: String, Codable, Sendable {
    case direct
    case preparing
    case connecting
    case connected
    case degraded
    case reconnecting
    case errorDirect = "error-direct"
    case stopping
}

public struct VPSEndpoint: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    public var user: String
    public var privateKeyPath: String
    public var hostKey: String

    public init(id: String, name: String, host: String, port: Int = 22, user: String = "root", privateKeyPath: String, hostKey: String) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.privateKeyPath = privateKeyPath
        self.hostKey = hostKey
    }
}

public enum ISPProtocol: String, Codable, Sendable {
    case socks
    case http
}

public struct ISPEndpoint: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var type: ISPProtocol
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var expectedEgressIP: String?

    public init(id: String, name: String, type: ISPProtocol, host: String, port: Int, username: String = "", password: String = "", expectedEgressIP: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.expectedEgressIP = expectedEgressIP
    }
}

public enum SubscriptionTLSPolicy: Codable, Sendable, Equatable {
    case system
    case pinnedSHA256(String)

    private enum CodingKeys: String, CodingKey { case mode, fingerprint }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .mode) {
        case "system": self = .system
        case "pinned-sha256": self = .pinnedSHA256(try container.decode(String.self, forKey: .fingerprint))
        default:
            throw DecodingError.dataCorruptedError(forKey: .mode, in: container, debugDescription: "Unknown TLS policy")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .system:
            try container.encode("system", forKey: .mode)
        case .pinnedSHA256(let fingerprint):
            try container.encode("pinned-sha256", forKey: .mode)
            try container.encode(fingerprint, forKey: .fingerprint)
        }
    }
}

public struct SubscriptionSource: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var url: String
    public var tlsPolicy: SubscriptionTLSPolicy
    public var refreshIntervalSeconds: Int

    public init(id: String, name: String, url: String, tlsPolicy: SubscriptionTLSPolicy = .system, refreshIntervalSeconds: Int = 21_600) {
        self.id = id
        self.name = name
        self.url = url
        self.tlsPolicy = tlsPolicy
        self.refreshIntervalSeconds = refreshIntervalSeconds
    }
}

public struct VMessNode: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var sourceID: String
    public var name: String
    public var host: String
    public var port: Int
    public var uuid: String
    public var alterID: Int
    public var security: String
    public var network: String
    public var path: String
    public var headerHost: String
    public var tlsEnabled: Bool
    public var serverName: String

    public init(id: String, sourceID: String, name: String, host: String, port: Int, uuid: String, alterID: Int = 0, security: String = "auto", network: String = "tcp", path: String = "", headerHost: String = "", tlsEnabled: Bool = false, serverName: String = "") {
        self.id = id
        self.sourceID = sourceID
        self.name = name
        self.host = host
        self.port = port
        self.uuid = uuid
        self.alterID = alterID
        self.security = security
        self.network = network
        self.path = path
        self.headerHost = headerHost
        self.tlsEnabled = tlsEnabled
        self.serverName = serverName
    }
}

public struct StableSelection: Codable, Sendable, Equatable {
    public var vpsID: String
    public var ispID: String

    public init(vpsID: String, ispID: String) {
        self.vpsID = vpsID
        self.ispID = ispID
    }
}

public struct SubscriptionSelection: Codable, Sendable, Equatable {
    public var sourceID: String
    public var nodeID: String

    public init(sourceID: String, nodeID: String) {
        self.sourceID = sourceID
        self.nodeID = nodeID
    }
}

public struct ProductConfiguration: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var vpsEndpoints: [VPSEndpoint]
    public var ispEndpoints: [ISPEndpoint]
    public var subscriptionSources: [SubscriptionSource]
    public var subscriptionNodes: [VMessNode]
    public var stableSelection: StableSelection?
    public var subscriptionSelection: SubscriptionSelection?

    public init(schemaVersion: Int = 1, vpsEndpoints: [VPSEndpoint] = [], ispEndpoints: [ISPEndpoint] = [], subscriptionSources: [SubscriptionSource] = [], subscriptionNodes: [VMessNode] = [], stableSelection: StableSelection? = nil, subscriptionSelection: SubscriptionSelection? = nil) {
        self.schemaVersion = schemaVersion
        self.vpsEndpoints = vpsEndpoints
        self.ispEndpoints = ispEndpoints
        self.subscriptionSources = subscriptionSources
        self.subscriptionNodes = subscriptionNodes
        self.stableSelection = stableSelection
        self.subscriptionSelection = subscriptionSelection
    }
}

public extension ProductConfiguration {
    func redactedForClient() -> ProductConfiguration {
        var copy = self
        copy.vpsEndpoints = copy.vpsEndpoints.map {
            var value = $0
            value.privateKeyPath = "<redacted>"
            value.hostKey = "<redacted>"
            return value
        }
        copy.ispEndpoints = copy.ispEndpoints.map {
            var value = $0
            value.username = value.username.isEmpty ? "" : "<redacted>"
            value.password = value.password.isEmpty ? "" : "<redacted>"
            return value
        }
        copy.subscriptionSources = copy.subscriptionSources.map {
            var value = $0
            value.url = Redactor.redact(value.url)
            return value
        }
        copy.subscriptionNodes = copy.subscriptionNodes.map {
            var value = $0
            value.uuid = "<redacted>"
            return value
        }
        return copy
    }
}

public struct ConnectionSnapshot: Codable, Sendable, Equatable {
    public var mode: VPNMode
    public var phase: ConnectionPhase
    public var routeName: String
    public var egressIP: String?
    public var latencyMilliseconds: Int?
    public var lastHealthyAt: Date?
    public var failureReason: String?
    public var reconnectAttempt: Int
    public var networkEnabled: Bool

    public init(mode: VPNMode = .direct, phase: ConnectionPhase = .direct, routeName: String = "Direct", egressIP: String? = nil, latencyMilliseconds: Int? = nil, lastHealthyAt: Date? = nil, failureReason: String? = nil, reconnectAttempt: Int = 0, networkEnabled: Bool = false) {
        self.mode = mode
        self.phase = phase
        self.routeName = routeName
        self.egressIP = egressIP
        self.latencyMilliseconds = latencyMilliseconds
        self.lastHealthyAt = lastHealthyAt
        self.failureReason = failureReason
        self.reconnectAttempt = reconnectAttempt
        self.networkEnabled = networkEnabled
    }
}

public struct APIRequest: Codable, Sendable {
    public var id: String
    public var method: String
    public var vpsID: String?
    public var ispID: String?
    public var sourceID: String?
    public var nodeID: String?
    public var payload: String?

    public init(id: String = UUID().uuidString, method: String, vpsID: String? = nil, ispID: String? = nil, sourceID: String? = nil, nodeID: String? = nil, payload: String? = nil) {
        self.id = id
        self.method = method
        self.vpsID = vpsID
        self.ispID = ispID
        self.sourceID = sourceID
        self.nodeID = nodeID
        self.payload = payload
    }
}

public struct APIResponse: Codable, Sendable {
    public var id: String
    public var ok: Bool
    public var message: String?
    public var snapshot: ConnectionSnapshot?
    public var configuration: ProductConfiguration?

    public init(id: String, ok: Bool, message: String? = nil, snapshot: ConnectionSnapshot? = nil, configuration: ProductConfiguration? = nil) {
        self.id = id
        self.ok = ok
        self.message = message
        self.snapshot = snapshot
        self.configuration = configuration
    }
}
