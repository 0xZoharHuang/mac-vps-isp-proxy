import Darwin
import Foundation
import Network
import PersonalVPNCore

private struct DaemonOptions {
    var socketPath = "/var/run/personalvpn/personalvpnd.sock"
    var stateDirectory = "/Library/Application Support/PersonalVPN"
    var singBoxPath = "/usr/local/libexec/personalvpn/sing-box"
    var networkEnabled = false
    var ownerUID = getuid()

    static func parse(_ arguments: [String]) -> DaemonOptions {
        var result = DaemonOptions()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--socket" where index + 1 < arguments.count: index += 1; result.socketPath = arguments[index]
            case "--state-dir" where index + 1 < arguments.count: index += 1; result.stateDirectory = arguments[index]
            case "--sing-box" where index + 1 < arguments.count: index += 1; result.singBoxPath = arguments[index]
            case "--network-enabled": result.networkEnabled = true
            case "--owner-uid" where index + 1 < arguments.count: index += 1; result.ownerUID = uid_t(arguments[index]) ?? getuid()
            default: break
            }
            index += 1
        }
        return result
    }
}

private final class TCPProbeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let connection: NWConnection
    private let continuation: CheckedContinuation<Int, Error>

    init(connection: NWConnection, continuation: CheckedContinuation<Int, Error>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ result: Result<Int, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        connection.cancel()
        continuation.resume(with: result)
    }
}

private actor VPNController {
    private let options: DaemonOptions
    private let configStore: AtomicJSONStore<ProductConfiguration>
    private let stateStore: AtomicJSONStore<ConnectionSnapshot>
    private var configuration: ProductConfiguration
    private var snapshot: ConnectionSnapshot
    private var engine: Process?
    private var healthTask: Task<Void, Never>?
    private var activeConfigData: Data?
    private var activeExpectedEgressIP: String?
    private var subscriptionTask: Task<Void, Never>?

    init(options: DaemonOptions) throws {
        self.options = options
        self.configStore = AtomicJSONStore(url: URL(fileURLWithPath: options.stateDirectory).appendingPathComponent("config.json"))
        self.stateStore = AtomicJSONStore(url: URL(fileURLWithPath: options.stateDirectory).appendingPathComponent("state.json"))
        self.configuration = try configStore.load(default: ProductConfiguration())
        self.snapshot = try stateStore.load(default: ConnectionSnapshot(networkEnabled: options.networkEnabled))
        self.snapshot.networkEnabled = options.networkEnabled
        if !options.networkEnabled {
            self.snapshot = ConnectionSnapshot(networkEnabled: false)
        }
    }

    func handle(_ request: APIRequest) async -> APIResponse {
        do {
            switch request.method {
            case "status.get":
                return APIResponse(id: request.id, ok: true, snapshot: snapshot)
            case "config.get":
                return APIResponse(id: request.id, ok: true, configuration: configuration.redactedForClient())
            case "config.replace":
                guard let payload = request.payload, let data = Data(base64Encoded: payload) else {
                    throw PersonalVPNError.invalidConfiguration("config.replace requires Base64 JSON payload")
                }
                let replacement = try JSONDecoder.productDecoder.decode(ProductConfiguration.self, from: data)
                guard replacement.schemaVersion == 1 else { throw PersonalVPNError.invalidConfiguration("unsupported schema version") }
                try configStore.save(replacement)
                configuration = replacement
                return APIResponse(id: request.id, ok: true, message: "configuration saved")
            case "vps.upsert":
                let value: VPSEndpoint = try decodePayload(request)
                configuration.vpsEndpoints.removeAll(where: { $0.id == value.id })
                configuration.vpsEndpoints.append(value)
                try configStore.save(configuration)
                return APIResponse(id: request.id, ok: true, configuration: configuration.redactedForClient())
            case "isp.upsert":
                let value: ISPEndpoint = try decodePayload(request)
                configuration.ispEndpoints.removeAll(where: { $0.id == value.id })
                configuration.ispEndpoints.append(value)
                try configStore.save(configuration)
                return APIResponse(id: request.id, ok: true, configuration: configuration.redactedForClient())
            case "subscription.upsert":
                let value: SubscriptionSource = try decodePayload(request)
                guard URL(string: value.url)?.scheme?.lowercased() == "https" else {
                    throw PersonalVPNError.invalidConfiguration("subscription URL must use HTTPS")
                }
                configuration.subscriptionSources.removeAll(where: { $0.id == value.id })
                configuration.subscriptionSources.append(value)
                try configStore.save(configuration)
                return APIResponse(id: request.id, ok: true, configuration: configuration.redactedForClient())
            case "vps.delete", "isp.delete", "subscription.delete":
                guard let identifier = request.payload else { throw PersonalVPNError.invalidConfiguration("delete requires identifier") }
                if request.method == "vps.delete" { configuration.vpsEndpoints.removeAll(where: { $0.id == identifier }) }
                if request.method == "isp.delete" { configuration.ispEndpoints.removeAll(where: { $0.id == identifier }) }
                if request.method == "subscription.delete" {
                    configuration.subscriptionSources.removeAll(where: { $0.id == identifier })
                    configuration.subscriptionNodes.removeAll(where: { $0.sourceID == identifier })
                }
                try configStore.save(configuration)
                return APIResponse(id: request.id, ok: true, configuration: configuration.redactedForClient())
            case "subscription.refresh":
                guard let sourceID = request.sourceID,
                      let source = configuration.subscriptionSources.first(where: { $0.id == sourceID }) else {
                    throw PersonalVPNError.invalidConfiguration("unknown subscription source")
                }
                let data = try await SubscriptionFetcher(policy: source.tlsPolicy).fetch(from: source)
                let nodes = try VMessSubscriptionParser.parse(data: data, sourceID: source.id)
                configuration.subscriptionNodes.removeAll(where: { $0.sourceID == source.id })
                configuration.subscriptionNodes.append(contentsOf: nodes)
                try configStore.save(configuration)
                return APIResponse(id: request.id, ok: true, message: "refreshed \(nodes.count) nodes", configuration: configuration.redactedForClient())
            case "probe.run":
                guard let nodeID = request.nodeID,
                      let node = configuration.subscriptionNodes.first(where: { $0.id == nodeID }) else {
                    throw PersonalVPNError.invalidConfiguration("probe.run requires a known node")
                }
                let latency = try await measureTCP(host: node.host, port: node.port)
                return APIResponse(id: request.id, ok: true, message: "entry_latency_ms=\(latency)")
            case "speedtest.run":
                let result = try await runDownloadSpeedTest()
                return APIResponse(id: request.id, ok: true, message: String(format: "download_mbps=%.2f bytes=%d", result.mbps, result.bytes))
            case "connect.direct":
                try stopEngine(errorReason: nil)
                return APIResponse(id: request.id, ok: true, snapshot: snapshot)
            case "connect.stable":
                guard let vpsID = request.vpsID, let ispID = request.ispID,
                      let vps = configuration.vpsEndpoints.first(where: { $0.id == vpsID }),
                      let isp = configuration.ispEndpoints.first(where: { $0.id == ispID }) else {
                    throw PersonalVPNError.invalidConfiguration("unknown VPS or ISP")
                }
                let data = try SingBoxConfigurationCompiler().compileStable(vps: vps, isp: isp)
                try startEngine(configData: data, mode: .stable, routeName: "\(vps.name) → \(isp.name)", expectedEgressIP: isp.expectedEgressIP)
                configuration.stableSelection = StableSelection(vpsID: vpsID, ispID: ispID)
                try configStore.save(configuration)
                return APIResponse(id: request.id, ok: true, snapshot: snapshot)
            case "connect.subscription":
                guard let sourceID = request.sourceID, let nodeID = request.nodeID,
                      let node = configuration.subscriptionNodes.first(where: { $0.sourceID == sourceID && $0.id == nodeID }) else {
                    throw PersonalVPNError.invalidConfiguration("unknown subscription node")
                }
                let data = try SingBoxConfigurationCompiler().compileSubscription(node: node)
                try startEngine(configData: data, mode: .subscription, routeName: node.name, expectedEgressIP: nil)
                configuration.subscriptionSelection = SubscriptionSelection(sourceID: sourceID, nodeID: nodeID)
                try configStore.save(configuration)
                return APIResponse(id: request.id, ok: true, snapshot: snapshot)
            default:
                return APIResponse(id: request.id, ok: false, message: "unknown method: \(request.method)")
            }
        } catch {
            return APIResponse(id: request.id, ok: false, message: Redactor.redact(error.localizedDescription), snapshot: snapshot)
        }
    }

    private func decodePayload<Value: Decodable>(_ request: APIRequest) throws -> Value {
        guard let payload = request.payload, let data = Data(base64Encoded: payload) else {
            throw PersonalVPNError.invalidConfiguration("request requires Base64 JSON payload")
        }
        return try JSONDecoder.productDecoder.decode(Value.self, from: data)
    }

    private func startEngine(configData: Data, mode: VPNMode, routeName: String, expectedEgressIP: String?) throws {
        try SafetyGate().assertNetworkMutationAllowed(networkFlag: options.networkEnabled)
        healthTask?.cancel()
        snapshot = ConnectionStateMachine.reduce(snapshot, event: .requestConnect(mode: mode, routeName: routeName))
        try stateStore.save(snapshot)

        let runtime = URL(fileURLWithPath: options.stateDirectory).appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let configURL = runtime.appendingPathComponent("sing-box.json")
        try configData.write(to: configURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)

        let check = Process()
        check.executableURL = URL(fileURLWithPath: options.singBoxPath)
        check.arguments = ["check", "-c", configURL.path]
        try check.run()
        check.waitUntilExit()
        guard check.terminationStatus == 0 else { throw PersonalVPNError.engineFailure("sing-box check failed") }

        if let engine, engine.isRunning { engine.terminate(); engine.waitUntilExit() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: options.singBoxPath)
        process.arguments = ["run", "-c", configURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        engine = process
        activeConfigData = configData
        activeExpectedEgressIP = expectedEgressIP
        snapshot = ConnectionStateMachine.reduce(snapshot, event: .engineStarted)
        try stateStore.save(snapshot)
        healthTask = Task { [weak self] in await self?.healthLoop() }
    }

    private func stopEngine(errorReason: String?) throws {
        healthTask?.cancel()
        healthTask = nil
        snapshot = ConnectionStateMachine.reduce(snapshot, event: .requestDirect)
        try stateStore.save(snapshot)
        if let engine, engine.isRunning {
            engine.terminate()
            engine.waitUntilExit()
        }
        engine = nil
        activeConfigData = nil
        activeExpectedEgressIP = nil
        snapshot = ConnectionStateMachine.reduce(snapshot, event: errorReason.map { .retriesExhausted(reason: $0) } ?? .engineStopped)
        try stateStore.save(snapshot)
    }

    private func healthLoop() async {
        var consecutiveFailures = 0
        while !Task.isCancelled, snapshot.mode != .direct {
            do {
                try await Task.sleep(for: .seconds(3))
                let result = try await probeEgress()
                if let expected = activeExpectedEgressIP, result.ip != expected {
                    snapshot = ConnectionStateMachine.reduce(snapshot, event: .probeFailed(reason: "egress-ip-mismatch expected=\(expected) actual=\(result.ip)"))
                    try? stateStore.save(snapshot)
                    consecutiveFailures = 0
                    try await Task.sleep(for: .seconds(12))
                    continue
                }
                snapshot = ConnectionStateMachine.reduce(snapshot, event: .probeSucceeded(ip: result.ip, latencyMilliseconds: result.latency))
                try? stateStore.save(snapshot)
                consecutiveFailures = 0
            } catch is CancellationError {
                return
            } catch {
                consecutiveFailures += 1
                snapshot = ConnectionStateMachine.reduce(snapshot, event: .probeFailed(reason: Redactor.redact(error.localizedDescription)))
                try? stateStore.save(snapshot)
                if consecutiveFailures >= 3 {
                    await reconnectSameRoute()
                    return
                }
            }
            try? await Task.sleep(for: .seconds(12))
        }
    }

    private func reconnectSameRoute() async {
        guard let configData = activeConfigData else { return }
        let originalMode = snapshot.mode
        let originalRoute = snapshot.routeName
        let expectedIP = activeExpectedEgressIP
        for (index, delay) in ConnectionStateMachine.reconnectDelays.enumerated() {
            if Task.isCancelled { return }
            snapshot = ConnectionStateMachine.reduce(snapshot, event: .retryStarted(attempt: index + 1))
            try? stateStore.save(snapshot)
            try? await Task.sleep(for: .seconds(delay))
            do {
                try launchValidatedEngine(configData: configData)
                let result = try await probeEgress()
                if let expectedIP, result.ip != expectedIP {
                    throw PersonalVPNError.engineFailure("egress IP changed during reconnect")
                }
                snapshot = ConnectionStateMachine.reduce(snapshot, event: .requestConnect(mode: originalMode, routeName: originalRoute))
                snapshot = ConnectionStateMachine.reduce(snapshot, event: .probeSucceeded(ip: result.ip, latencyMilliseconds: result.latency))
                try? stateStore.save(snapshot)
                healthTask = Task { [weak self] in await self?.healthLoop() }
                return
            } catch {
                continue
            }
        }
        do { try stopEngine(errorReason: "same route unavailable after 5 attempts") }
        catch {
            snapshot = ConnectionStateMachine.reduce(snapshot, event: .retriesExhausted(reason: "engine cleanup failed"))
            try? stateStore.save(snapshot)
        }
    }

    private func launchValidatedEngine(configData: Data) throws {
        let runtime = URL(fileURLWithPath: options.stateDirectory).appendingPathComponent("runtime")
        let configURL = runtime.appendingPathComponent("sing-box.json")
        if let engine, engine.isRunning { engine.terminate(); engine.waitUntilExit() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: options.singBoxPath)
        process.arguments = ["run", "-c", configURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        engine = process
    }

    private func probeEgress() async throws -> (ip: String, latency: Int) {
        let urls = ["https://api64.ipify.org", "https://ipv4.icanhazip.com", "https://ifconfig.me/ip"]
        var lastError: Error = PersonalVPNError.engineFailure("all egress probes failed")
        for value in urls {
            do {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 5
                let session = URLSession(configuration: configuration)
                let started = ContinuousClock.now
                let (data, response) = try await session.data(from: URL(string: value)!)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      body.range(of: #"^([0-9]{1,3}\.){3}[0-9]{1,3}$"#, options: .regularExpression) != nil else {
                    throw PersonalVPNError.engineFailure("invalid egress probe response")
                }
                let elapsed = started.duration(to: .now).components
                let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
                return (body, Int(milliseconds))
            } catch { lastError = error }
        }
        throw lastError
    }

    func shutdown() {
        subscriptionTask?.cancel()
        try? stopEngine(errorReason: nil)
    }

    func startBackgroundTasks() {
        guard subscriptionTask == nil else { return }
        subscriptionTask = Task { [weak self] in await self?.subscriptionRefreshLoop() }
    }

    private func subscriptionRefreshLoop() async {
        var nextRefresh: [String: Date] = [:]
        while !Task.isCancelled {
            let now = Date()
            for source in configuration.subscriptionSources {
                if nextRefresh[source.id] == nil {
                    nextRefresh[source.id] = now.addingTimeInterval(TimeInterval(max(source.refreshIntervalSeconds, 300)))
                    continue
                }
                guard nextRefresh[source.id]! <= now else { continue }
                do { try await refresh(source: source) }
                catch {
                    FileHandle.standardError.write(Data("subscription_refresh_error source=\(source.id) reason=\(Redactor.redact(error.localizedDescription))\n".utf8))
                }
                nextRefresh[source.id] = Date().addingTimeInterval(TimeInterval(max(source.refreshIntervalSeconds, 300)))
            }
            let activeIDs = Set(configuration.subscriptionSources.map(\.id))
            nextRefresh = nextRefresh.filter { activeIDs.contains($0.key) }
            try? await Task.sleep(for: .seconds(60))
        }
    }

    private func refresh(source: SubscriptionSource) async throws {
        let data = try await SubscriptionFetcher(policy: source.tlsPolicy).fetch(from: source)
        let nodes = try VMessSubscriptionParser.parse(data: data, sourceID: source.id)
        configuration.subscriptionNodes.removeAll(where: { $0.sourceID == source.id })
        configuration.subscriptionNodes.append(contentsOf: nodes)
        try configStore.save(configuration)
    }

    private func measureTCP(host: String, port: Int) async throws -> Int {
        let started = ContinuousClock.now
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: UInt16(port)), using: .tcp)
        return try await withCheckedThrowingContinuation { continuation in
            let completion = TCPProbeCompletion(connection: connection, continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsed = started.duration(to: .now).components
                    completion.finish(.success(Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)))
                case .failed(let error): completion.finish(.failure(error))
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                completion.finish(.failure(PersonalVPNError.engineFailure("TCP probe timed out")))
            }
        }
    }

    private func runDownloadSpeedTest() async throws -> (mbps: Double, bytes: Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        let session = URLSession(configuration: configuration)
        let started = ContinuousClock.now
        let (data, response) = try await session.data(from: URL(string: "https://speed.cloudflare.com/__down?bytes=10000000")!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw PersonalVPNError.engineFailure("speed test failed")
        }
        let elapsed = started.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        return (Double(data.count) * 8 / max(seconds, 0.001) / 1_000_000, data.count)
    }
}

private final class UnixSocketServer {
    private let path: String
    private let ownerUID: uid_t
    private var descriptor: Int32 = -1

    init(path: String, ownerUID: uid_t) { self.path = path; self.ownerUID = ownerUID }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    func start() throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw PersonalVPNError.apiFailure("socket failed") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw PersonalVPNError.apiFailure("socket path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in path.utf8.enumerated() { raw[index] = byte }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, length) }
        }
        guard bound == 0, Darwin.listen(descriptor, 16) == 0 else { throw PersonalVPNError.apiFailure("bind/listen failed") }
        chmod(path, 0o600)
        chown(path, ownerUID, gid_t.max)
    }

    func nextRequest() throws -> (Int32, APIRequest) {
        let client = Darwin.accept(descriptor, nil, nil)
        guard client >= 0 else { throw PersonalVPNError.apiFailure("accept failed") }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == ownerUID || peerUID == 0 else {
            Darwin.close(client)
            throw PersonalVPNError.apiFailure("peer UID is not authorized")
        }
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 2_000_000 {
            let count = Darwin.read(client, &byte, 1)
            guard count >= 0 else { Darwin.close(client); throw PersonalVPNError.apiFailure("read failed") }
            if count == 0 || byte == 0x0A { break }
            data.append(byte)
        }
        do { return (client, try JSONDecoder.productDecoder.decode(APIRequest.self, from: data)) }
        catch { Darwin.close(client); throw error }
    }

    func respond(_ response: APIResponse, to client: Int32) {
        defer { Darwin.close(client) }
        guard var data = try? JSONEncoder.wireEncoder.encode(response) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in _ = Darwin.write(client, raw.baseAddress, raw.count) }
    }
}

@main
private enum PersonalVPNDaemonMain {
    static func main() async throws {
        let options = DaemonOptions.parse(Array(CommandLine.arguments.dropFirst()))
        let controller = try VPNController(options: options)
        await controller.startBackgroundTasks()
        let server = UnixSocketServer(path: options.socketPath, ownerUID: options.ownerUID)
        try server.start()
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let shutdown: @Sendable () -> Void = {
            Task {
                await controller.shutdown()
                Foundation.exit(0)
            }
        }
        terminate.setEventHandler(handler: shutdown)
        interrupt.setEventHandler(handler: shutdown)
        terminate.resume()
        interrupt.resume()
        FileHandle.standardError.write(Data("personalvpnd ready network_enabled=\(options.networkEnabled)\n".utf8))
        while true {
            do {
                let (client, request) = try server.nextRequest()
                let response = await controller.handle(request)
                server.respond(response, to: client)
            } catch {
                let message = Redactor.redact(error.localizedDescription)
                FileHandle.standardError.write(Data("personalvpnd request_error=\(message)\n".utf8))
            }
        }
    }
}
