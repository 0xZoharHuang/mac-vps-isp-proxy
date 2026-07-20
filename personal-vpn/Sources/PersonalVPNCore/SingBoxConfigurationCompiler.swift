import Foundation

public struct SingBoxConfigurationCompiler: Sendable {
    public struct Options: Sendable {
        public var tunAddress: String
        public var mtu: Int
        public var strictRoute: Bool
        public var logLevel: String
        public var stack: String

        public init(tunAddress: String = "172.31.251.1/30", mtu: Int = 1_408, strictRoute: Bool = true, logLevel: String = "info", stack: String = "gvisor") {
            self.tunAddress = tunAddress
            self.mtu = mtu
            self.strictRoute = strictRoute
            self.logLevel = logLevel
            self.stack = stack
        }
    }

    public init() {}

    public func compileStable(vps: VPSEndpoint, isp: ISPEndpoint, options: Options = .init()) throws -> Data {
        try validate(vps: vps, isp: isp)
        let hostKeys = vps.hostKey.split(whereSeparator: \.isNewline).map(String.init)
        let ssh: [String: Any] = [
            "type": "ssh", "tag": "stable-vps", "server": vps.host, "server_port": vps.port,
            "user": vps.user, "private_key_path": vps.privateKeyPath, "host_key": hostKeys,
            "connect_timeout": "8s",
        ]
        var upstream: [String: Any] = [
            "type": isp.type.rawValue, "tag": "selected", "server": isp.host, "server_port": isp.port,
            "detour": "stable-vps",
        ]
        if !isp.username.isEmpty { upstream["username"] = isp.username }
        if !isp.password.isEmpty { upstream["password"] = isp.password }
        if isp.type == .socks { upstream["version"] = "5" }
        return try serialize(outbounds: [upstream, ssh, directOutbound()], final: "selected", exclusions: [vps.host, isp.host], options: options)
    }

    public func compileSubscription(node: VMessNode, options: Options = .init()) throws -> Data {
        guard !node.host.isEmpty, (1...65_535).contains(node.port), UUID(uuidString: node.uuid) != nil else {
            throw PersonalVPNError.invalidConfiguration("VMess endpoint is incomplete")
        }
        var outbound: [String: Any] = [
            "type": "vmess", "tag": "selected", "server": node.host, "server_port": node.port,
            "uuid": node.uuid, "security": node.security, "alter_id": node.alterID,
        ]
        switch node.network.lowercased() {
        case "", "tcp": break
        case "ws":
            var headers: [String: String] = [:]
            if !node.headerHost.isEmpty { headers["Host"] = node.headerHost }
            outbound["transport"] = ["type": "ws", "path": node.path.isEmpty ? "/" : node.path, "headers": headers]
        default:
            throw PersonalVPNError.unsupportedProtocol("VMess transport \(node.network)")
        }
        if node.tlsEnabled {
            var tls: [String: Any] = ["enabled": true]
            if !node.serverName.isEmpty { tls["server_name"] = node.serverName }
            outbound["tls"] = tls
        }
        return try serialize(outbounds: [outbound, directOutbound()], final: "selected", exclusions: [node.host], options: options)
    }

    private func validate(vps: VPSEndpoint, isp: ISPEndpoint) throws {
        guard !vps.host.isEmpty, (1...65_535).contains(vps.port), !vps.user.isEmpty, !vps.privateKeyPath.isEmpty else {
            throw PersonalVPNError.invalidConfiguration("VPS endpoint is incomplete")
        }
        guard !vps.hostKey.isEmpty else {
            throw PersonalVPNError.invalidConfiguration("SSH host key pin is required")
        }
        guard !isp.host.isEmpty, (1...65_535).contains(isp.port) else {
            throw PersonalVPNError.invalidConfiguration("ISP endpoint is incomplete")
        }
    }

    private func serialize(outbounds: [[String: Any]], final: String, exclusions: [String], options: Options = .init()) throws -> Data {
        let privateExclusions = ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10"]
        let endpointExclusions = exclusions.compactMap(normalizedRouteExclusion)
        let routeExclusions = privateExclusions + endpointExclusions
        var routeRules: [[String: Any]] = [
            ["protocol": "dns", "action": "hijack-dns"],
            ["network": "udp", "action": "reject"],
        ]
        if !endpointExclusions.isEmpty {
            routeRules.append(["ip_cidr": endpointExclusions, "outbound": "direct"])
        }
        routeRules.append(["ip_is_private": true, "outbound": "direct"])
        let config: [String: Any] = [
            "log": ["level": options.logLevel, "timestamp": true],
            "dns": [
                "servers": [
                    ["type": "local", "tag": "bootstrap"],
                    [
                        "type": "https", "tag": "secure-dns", "server": "1.1.1.1", "server_port": 443,
                        "tls": ["enabled": true, "server_name": "cloudflare-dns.com"], "detour": final,
                    ],
                ],
                "final": "secure-dns", "strategy": "prefer_ipv4",
            ],
            "inbounds": [[
                "type": "tun", "tag": "in-tun", "address": [options.tunAddress], "mtu": options.mtu,
                "auto_route": true, "strict_route": options.strictRoute, "stack": options.stack, "sniff": true,
                "route_exclude_address": routeExclusions,
            ]],
            "outbounds": outbounds,
            "route": [
                "rules": routeRules,
                "final": final, "auto_detect_interface": true, "default_domain_resolver": "bootstrap",
            ],
        ]
        guard JSONSerialization.isValidJSONObject(config) else {
            throw PersonalVPNError.invalidConfiguration("Generated sing-box object is not valid JSON")
        }
        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func directOutbound() -> [String: Any] { ["type": "direct", "tag": "direct"] }

    private func normalizedRouteExclusion(_ host: String) -> String? {
        if host.contains("/") { return host }
        let octets = host.split(separator: ".")
        if octets.count == 4, octets.allSatisfy({ Int($0).map { (0...255).contains($0) } == true }) {
            return "\(host)/32"
        }
        if host.contains(":") { return "\(host)/128" }
        return nil
    }
}
