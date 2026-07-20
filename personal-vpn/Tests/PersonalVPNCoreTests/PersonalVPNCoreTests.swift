import Foundation
import Testing
@testable import PersonalVPNCore

@Test func processTerminationIsBounded() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    let started = Date()
    #expect(ProcessTerminator.stop(process, graceSeconds: 0.1))
    #expect(Date().timeIntervalSince(started) < 2)
}

@Test func parsesBase64VMessSubscriptionAndDeduplicates() throws {
    let payload: [String: Any] = [
        "ps": "Tokyo", "add": "example.com", "port": "443", "id": "95a7457b-391c-43b7-8476-6415ed805fc9",
        "aid": "0", "scy": "auto", "net": "ws", "path": "/vpn", "host": "cdn.example.com", "tls": "tls", "sni": "cdn.example.com",
    ]
    let json = try JSONSerialization.data(withJSONObject: payload)
    let uri = "vmess://\(json.base64EncodedString())"
    let subscription = Data("\(uri)\n\(uri)\n".utf8).base64EncodedData()
    let nodes = try VMessSubscriptionParser.parse(data: subscription, sourceID: "primary")
    #expect(nodes.count == 1)
    #expect(nodes[0].name == "Tokyo")
    #expect(nodes[0].network == "ws")
    #expect(nodes[0].tlsEnabled)
}

@Test func rejectsSubscriptionWithoutSupportedNodes() {
    #expect(throws: PersonalVPNError.self) {
        try VMessSubscriptionParser.parse(data: Data("c3M6Ly9ub3Qtc3VwcG9ydGVk".utf8), sourceID: "bad")
    }
}

@Test func stableConfigUsesSSHDetourAndKeepsExpectedExitSeparate() throws {
    let vps = VPSEndpoint(id: "vps", name: "VPS", host: "203.0.113.10", port: 443, privateKeyPath: "/tmp/key", hostKey: "ssh-ed25519 AAAATEST\necdsa-sha2-nistp256 AAAAOTHER")
    let isp = ISPEndpoint(id: "isp", name: "ISP", type: .socks, host: "198.51.100.20", port: 1080, username: "user\"name", password: "p\\ass", expectedEgressIP: "203.0.113.8")
    let data = try SingBoxConfigurationCompiler().compileStable(vps: vps, isp: isp)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let outbounds = try #require(object["outbounds"] as? [[String: Any]])
    #expect(outbounds[0]["detour"] as? String == "stable-vps")
    #expect(outbounds[0]["password"] as? String == "p\\ass")
    #expect((outbounds[1]["host_key"] as? [String])?.count == 2)
    let route = try #require(object["route"] as? [String: Any])
    let rules = try #require(route["rules"] as? [[String: Any]])
    #expect(rules.contains { $0["network"] as? String == "udp" && $0["action"] as? String == "reject" })
    let inbound = try #require((object["inbounds"] as? [[String: Any]])?.first)
    #expect(inbound["stack"] as? String == "gvisor")
    #expect((inbound["route_exclude_address"] as? [String])?.contains("203.0.113.10/32") == true)
    #expect((inbound["route_exclude_address"] as? [String])?.contains("198.51.100.20/32") == true)
    #expect(!String(decoding: data, as: UTF8.self).contains("203.0.113.8"))
    #expect(!String(decoding: data, as: UTF8.self).contains("cache.db"))
}

@Test func VMessConfigSupportsWebSocketTLS() throws {
    let node = VMessNode(id: "n", sourceID: "s", name: "Node", host: "node.example.com", port: 443, uuid: "95a7457b-391c-43b7-8476-6415ed805fc9", network: "ws", path: "/ws", headerHost: "cdn.example.com", tlsEnabled: true, serverName: "cdn.example.com")
    let data = try SingBoxConfigurationCompiler().compileSubscription(node: node)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"transport\""))
    #expect(text.contains("\"server_name\""))
}

@Test func stateMachineNeverSilentlySwitchesRoute() {
    var state = ConnectionSnapshot()
    state = ConnectionStateMachine.reduce(state, event: .requestConnect(mode: .stable, routeName: "VPS A → ISP A"))
    state = ConnectionStateMachine.reduce(state, event: .engineStarted)
    state = ConnectionStateMachine.reduce(state, event: .probeFailed(reason: "timeout"))
    for attempt in 1...5 {
        state = ConnectionStateMachine.reduce(state, event: .retryStarted(attempt: attempt))
        #expect(state.routeName == "VPS A → ISP A")
    }
    state = ConnectionStateMachine.reduce(state, event: .retriesExhausted(reason: "same route unavailable"))
    #expect(state.mode == .direct)
    #expect(state.phase == .errorDirect)
}

@Test func safetyGateDefaultsToDenyAndAllowsInjectedVM() throws {
    let denied = SafetyGate(markerPath: "/definitely/missing", environment: [:], isVirtualMachine: false)
    #expect(throws: PersonalVPNError.self) { try denied.assertNetworkMutationAllowed(networkFlag: true) }
    let vm = SafetyGate(markerPath: "/definitely/missing", environment: [:], isVirtualMachine: true)
    try vm.assertNetworkMutationAllowed(networkFlag: true)
}

@Test func redactsURLTokensAndJSONPasswords() {
    let value = "GET /subscribe?token=secret-value&x=1 {\"password\":\"hunter2\"}"
    let redacted = Redactor.redact(value)
    #expect(!redacted.contains("secret-value"))
    #expect(!redacted.contains("hunter2"))
}

@Test func atomicStoreRoundTrips() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AtomicJSONStore<ProductConfiguration>(url: root.appendingPathComponent("config.json"))
    let value = ProductConfiguration(vpsEndpoints: [VPSEndpoint(id: "a", name: "A", host: "host", privateKeyPath: "/key", hostKey: "pin")])
    try store.save(value)
    #expect(try store.load(default: ProductConfiguration()) == value)
}

@Test func clientConfigurationDoesNotExposeSecrets() {
    let source = SubscriptionSource(id: "s", name: "S", url: "https://example.com/sub?token=secret")
    let node = VMessNode(id: "n", sourceID: "s", name: "N", host: "host", port: 443, uuid: "95a7457b-391c-43b7-8476-6415ed805fc9")
    let value = ProductConfiguration(
        vpsEndpoints: [VPSEndpoint(id: "v", name: "V", host: "host", privateKeyPath: "/secret/key", hostKey: "secret-key")],
        ispEndpoints: [ISPEndpoint(id: "i", name: "I", type: .socks, host: "host", port: 1, username: "u", password: "p")],
        subscriptionSources: [source], subscriptionNodes: [node]
    ).redactedForClient()
    #expect(value.vpsEndpoints[0].privateKeyPath == "<redacted>")
    #expect(value.ispEndpoints[0].password == "<redacted>")
    #expect(!value.subscriptionSources[0].url.contains("secret"))
    #expect(value.subscriptionNodes[0].uuid == "<redacted>")
}

@Test func generatedSubscriptionConfigPassesInstalledSingBoxCheck() throws {
    let binary = URL(fileURLWithPath: "/opt/homebrew/bin/sing-box")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let node = VMessNode(id: "n", sourceID: "s", name: "Node", host: "node.example.com", port: 443, uuid: "95a7457b-391c-43b7-8476-6415ed805fc9", network: "ws", path: "/ws", tlsEnabled: true, serverName: "node.example.com")
    let config = try SingBoxConfigurationCompiler().compileSubscription(node: node)
    let url = root.appendingPathComponent("config.json")
    try config.write(to: url)
    let process = Process()
    process.executableURL = binary
    process.arguments = ["check", "-c", url.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

@Test func generatedStableSSHDetourConfigPassesInstalledSingBoxCheck() throws {
    let binary = URL(fileURLWithPath: "/opt/homebrew/bin/sing-box")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let keyURL = root.appendingPathComponent("id_ed25519")
    let keygen = Process()
    keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", keyURL.path]
    try keygen.run()
    keygen.waitUntilExit()
    try #require(keygen.terminationStatus == 0)
    let hostKey = try String(contentsOf: keyURL.appendingPathExtension("pub"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let vps = VPSEndpoint(id: "v", name: "V", host: "203.0.113.10", port: 443, privateKeyPath: keyURL.path, hostKey: hostKey)
    let isp = ISPEndpoint(id: "i", name: "I", type: .socks, host: "198.51.100.20", port: 1080)
    let config = try SingBoxConfigurationCompiler().compileStable(vps: vps, isp: isp)
    let configURL = root.appendingPathComponent("config.json")
    try config.write(to: configURL)
    let process = Process()
    process.executableURL = binary
    process.arguments = ["check", "-c", configURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

@Test func TLSSubscriptionPolicyHasStableExternalShape() throws {
    let value = SubscriptionSource(id: "s", name: "S", url: "https://example.com", tlsPolicy: .pinnedSHA256("abcdef"))
    let data = try JSONEncoder.productEncoder.encode(value)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"mode\" : \"pinned-sha256\""))
    #expect(text.contains("\"fingerprint\" : \"abcdef\""))
    #expect(try JSONDecoder.productDecoder.decode(SubscriptionSource.self, from: data) == value)
}
