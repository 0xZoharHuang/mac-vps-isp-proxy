import Darwin
import Foundation

public struct UnixSocketClient: Sendable {
    public var socketPath: String
    public var timeoutSeconds: Int

    public init(socketPath: String = "/var/run/personalvpn/personalvpnd.sock", timeoutSeconds: Int = 3) {
        self.socketPath = socketPath
        self.timeoutSeconds = timeoutSeconds
    }

    public func send(_ request: APIRequest) throws -> APIResponse {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw PersonalVPNError.apiFailure("socket: \(lastPOSIXError())") }
        defer { Darwin.close(descriptor) }

        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw PersonalVPNError.apiFailure("socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in socketPath.utf8.enumerated() { raw[index] = byte }
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + socketPath.utf8.count + 1)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, length) }
        }
        guard connected == 0 else { throw PersonalVPNError.apiFailure("connect: \(lastPOSIXError())") }

        var outgoing = try JSONEncoder.wireEncoder.encode(request)
        outgoing.append(0x0A)
        try outgoing.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                guard count > 0 else { throw PersonalVPNError.apiFailure("write: \(lastPOSIXError())") }
                sent += count
            }
        }

        var response = Data()
        var byte: UInt8 = 0
        while response.count < 2_000_000 {
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 0 { break }
            guard count > 0 else { throw PersonalVPNError.apiFailure("read: \(lastPOSIXError())") }
            if byte == 0x0A { break }
            response.append(byte)
        }
        guard !response.isEmpty else { throw PersonalVPNError.apiFailure("empty daemon response") }
        return try JSONDecoder.productDecoder.decode(APIResponse.self, from: response)
    }

    private func lastPOSIXError() -> String { String(cString: strerror(errno)) }
}
