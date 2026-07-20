import PersonalVPNCore
import SwiftUI

@MainActor
private final class VPNViewModel: ObservableObject {
    @Published var snapshot = ConnectionSnapshot()
    @Published var errorMessage: String?
    @Published var configuration = ProductConfiguration()
    private let client = UnixSocketClient()
    private var timer: Timer?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        refresh()
        refreshConfiguration()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func refresh() {
        perform(APIRequest(method: "status.get")) { response in
            if let value = response.snapshot { self.snapshot = value }
        }
    }

    func direct() {
        perform(APIRequest(method: "connect.direct")) { response in
            if let value = response.snapshot { self.snapshot = value }
        }
    }

    func refreshConfiguration() {
        perform(APIRequest(method: "config.get")) { response in
            if let value = response.configuration { self.configuration = value }
        }
    }

    func connectStable(vpsID: String, ispID: String) { perform(APIRequest(method: "connect.stable", vpsID: vpsID, ispID: ispID)) }
    func connectSubscription(sourceID: String, nodeID: String) { perform(APIRequest(method: "connect.subscription", sourceID: sourceID, nodeID: nodeID)) }
    func refreshSubscription(sourceID: String) {
        perform(APIRequest(method: "subscription.refresh", sourceID: sourceID), timeoutSeconds: 30) { response in
            if let value = response.configuration { self.configuration = value }
        }
    }

    private func perform(_ request: APIRequest, timeoutSeconds: Int = 5, update: (@MainActor (APIResponse) -> Void)? = nil) {
        let socketPath = client.socketPath
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try UnixSocketClient(socketPath: socketPath, timeoutSeconds: timeoutSeconds).send(request) }
            }.value
            switch result {
            case .success(let response):
                update?(response)
                if let value = response.snapshot { snapshot = value }
                errorMessage = response.ok ? nil : response.message
            case .failure(let error):
                errorMessage = request.method == "status.get" ? "Daemon unavailable" : error.localizedDescription
            }
        }
    }

    func upsert<T: Encodable>(_ value: T, method: String) {
        do {
            let payload = try JSONEncoder.productEncoder.encode(value).base64EncodedString()
            perform(APIRequest(method: method, payload: payload)) { response in
                if let value = response.configuration { self.configuration = value }
            }
        } catch { errorMessage = error.localizedDescription }
    }
}

@main
private struct PersonalVPNMenuApp: App {
    @StateObject private var model = VPNViewModel()

    var body: some Scene {
        MenuBarExtra(label) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Mode: \(model.snapshot.mode.rawValue)")
                Text("State: \(model.snapshot.phase.rawValue)")
                Text("Route: \(model.snapshot.routeName)")
                if let ip = model.snapshot.egressIP { Text("Exit IP: \(ip)") }
                if let reason = model.snapshot.failureReason { Text(reason).foregroundStyle(.orange) }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
                Divider()
                if !model.configuration.vpsEndpoints.isEmpty && !model.configuration.ispEndpoints.isEmpty {
                    Menu("Stable IP") {
                        ForEach(model.configuration.vpsEndpoints) { vps in
                            Menu(vps.name) {
                                ForEach(model.configuration.ispEndpoints) { isp in
                                    Button(isp.name) { model.connectStable(vpsID: vps.id, ispID: isp.id) }
                                }
                            }
                        }
                    }
                }
                if !model.configuration.subscriptionNodes.isEmpty {
                    Menu("Subscription Nodes") {
                        ForEach(model.configuration.subscriptionNodes.prefix(50)) { node in
                            Button(node.name) { model.connectSubscription(sourceID: node.sourceID, nodeID: node.id) }
                        }
                    }
                }
                if !model.configuration.subscriptionSources.isEmpty {
                    Menu("Refresh Subscription") {
                        ForEach(model.configuration.subscriptionSources) { source in
                            Button(source.name) { model.refreshSubscription(sourceID: source.id) }
                        }
                    }
                }
                Divider()
                Button("Restore Direct") { model.direct() }
                Button("Refresh") { model.refresh() }
                Divider()
                SettingsLink { Text("Settings…") }
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .padding(8)
            .onAppear { model.start() }
        }
        Settings {
            SettingsView(model: model)
        }
    }

    private var label: String {
        switch model.snapshot.phase {
        case .connected: "PVPN ✓"
        case .direct: "PVPN Direct"
        case .errorDirect: "PVPN !"
        default: "PVPN …"
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: VPNViewModel
    @State private var tab = 0
    @State private var vpsName = ""
    @State private var vpsHost = ""
    @State private var vpsPort = "443"
    @State private var vpsUser = "root"
    @State private var keyPath = ""
    @State private var hostKey = ""
    @State private var ispName = ""
    @State private var ispHost = ""
    @State private var ispPort = ""
    @State private var ispUser = ""
    @State private var ispPassword = ""
    @State private var expectedIP = ""
    @State private var subscriptionName = ""
    @State private var subscriptionURL = ""

    var body: some View {
        TabView(selection: $tab) {
            Form {
                TextField("Name", text: $vpsName)
                TextField("Host", text: $vpsHost)
                TextField("Port", text: $vpsPort)
                TextField("User", text: $vpsUser)
                TextField("Private key path", text: $keyPath)
                TextField("Pinned SSH host key", text: $hostKey)
                Button("Save VPS") {
                    guard let port = Int(vpsPort), !vpsName.isEmpty, !vpsHost.isEmpty else { return }
                    let id = slug(vpsName)
                    model.upsert(VPSEndpoint(id: id, name: vpsName, host: vpsHost, port: port, user: vpsUser, privateKeyPath: keyPath, hostKey: hostKey), method: "vps.upsert")
                }
                Divider()
                ForEach(model.configuration.vpsEndpoints) { Text("\($0.name) — \($0.host):\($0.port)") }
            }.tabItem { Text("VPS") }.tag(0)
            Form {
                TextField("Name", text: $ispName)
                TextField("Host", text: $ispHost)
                TextField("Port", text: $ispPort)
                TextField("Username", text: $ispUser)
                SecureField("Password", text: $ispPassword)
                TextField("Expected exit IP (optional)", text: $expectedIP)
                Button("Save SOCKS ISP") {
                    guard let port = Int(ispPort), !ispName.isEmpty, !ispHost.isEmpty else { return }
                    model.upsert(ISPEndpoint(id: slug(ispName), name: ispName, type: .socks, host: ispHost, port: port, username: ispUser, password: ispPassword, expectedEgressIP: expectedIP.isEmpty ? nil : expectedIP), method: "isp.upsert")
                    ispPassword = ""
                }
                Divider()
                ForEach(model.configuration.ispEndpoints) { Text("\($0.name) — \($0.host):\($0.port)") }
            }.tabItem { Text("ISP") }.tag(1)
            Form {
                TextField("Name", text: $subscriptionName)
                TextField("HTTPS subscription URL", text: $subscriptionURL)
                Button("Save Subscription") {
                    guard !subscriptionName.isEmpty, !subscriptionURL.isEmpty else { return }
                    model.upsert(SubscriptionSource(id: slug(subscriptionName), name: subscriptionName, url: subscriptionURL), method: "subscription.upsert")
                    subscriptionURL = ""
                }
                Divider()
                ForEach(model.configuration.subscriptionSources) { Text($0.name) }
            }.tabItem { Text("Subscriptions") }.tag(2)
        }
        .padding(16)
        .frame(width: 560, height: 420)
        .onAppear { model.refreshConfiguration() }
    }

    private func slug(_ value: String) -> String {
        value.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    }
}
