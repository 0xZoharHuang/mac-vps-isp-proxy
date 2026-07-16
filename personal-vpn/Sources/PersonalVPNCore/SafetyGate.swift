import Darwin
import Foundation

public struct SafetyGate: Sendable {
    public var markerPath: String
    public var environment: [String: String]
    public var isVirtualMachine: Bool

    public init(markerPath: String = "/Library/Application Support/PersonalVPN/host-canary-approved", environment: [String: String] = ProcessInfo.processInfo.environment, isVirtualMachine: Bool = SafetyGate.detectVirtualMachine()) {
        self.markerPath = markerPath
        self.environment = environment
        self.isVirtualMachine = isVirtualMachine
    }

    public func assertNetworkMutationAllowed(networkFlag: Bool) throws {
        guard networkFlag else {
            throw PersonalVPNError.safetyGateDenied("daemon was not started with --network-enabled")
        }
        if isVirtualMachine { return }
        guard environment["PERSONALVPN_ALLOW_HOST_NETWORK"] == "I_UNDERSTAND_THIS_CHANGES_ROUTES" else {
            throw PersonalVPNError.safetyGateDenied("host network environment acknowledgement is absent")
        }
        guard FileManager.default.fileExists(atPath: markerPath) else {
            throw PersonalVPNError.safetyGateDenied("host canary approval marker is absent")
        }
    }

    public static func detectVirtualMachine() -> Bool {
        let values = [
            ProcessInfo.processInfo.environment["PARALLELS_VM"],
            ProcessInfo.processInfo.environment["VIRTUAL_ENVIRONMENT"],
        ]
        if values.contains(where: { $0 != nil }) { return true }
        var size = 0
        sysctlbyname("kern.hv_vmm_present", nil, &size, nil, 0)
        guard size > 0 else { return false }
        var value: Int32 = 0
        sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0)
        return value == 1
    }
}
