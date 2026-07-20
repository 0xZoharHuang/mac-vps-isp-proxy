import Foundation
import PersonalVPNCore

private func usage() -> Never {
    print("""
    Usage: personalvpnctl [--socket PATH] <command>
      status
      direct
      stable <vps-id> <isp-id>
      subscription <source-id> <node-id>
      config-show
      config-import <json-file>
      refresh <source-id>
      probe <node-id>
      speedtest
      doctor
    """)
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var socketPath = ProcessInfo.processInfo.environment["PERSONALVPN_SOCKET"] ?? "/var/run/personalvpn/personalvpnd.sock"
if arguments.first == "--socket", arguments.count >= 2 {
    socketPath = arguments[1]
    arguments.removeFirst(2)
}
guard let command = arguments.first else { usage() }

let request: APIRequest
switch command {
case "status": request = APIRequest(method: "status.get")
case "direct": request = APIRequest(method: "connect.direct")
case "stable" where arguments.count == 3: request = APIRequest(method: "connect.stable", vpsID: arguments[1], ispID: arguments[2])
case "subscription" where arguments.count == 3: request = APIRequest(method: "connect.subscription", sourceID: arguments[1], nodeID: arguments[2])
case "config-show": request = APIRequest(method: "config.get")
case "config-import" where arguments.count == 2:
    let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
    request = APIRequest(method: "config.replace", payload: data.base64EncodedString())
case "refresh" where arguments.count == 2: request = APIRequest(method: "subscription.refresh", sourceID: arguments[1])
case "probe" where arguments.count == 2: request = APIRequest(method: "probe.run", nodeID: arguments[1])
case "speedtest": request = APIRequest(method: "speedtest.run")
case "doctor": request = APIRequest(method: "doctor.run")
default: usage()
}

do {
    let longRunning = ["speedtest.run", "subscription.refresh"].contains(request.method)
    let response = try UnixSocketClient(socketPath: socketPath, timeoutSeconds: longRunning ? 30 : 5).send(request)
    let data = try JSONEncoder.productEncoder.encode(response)
    print(String(decoding: data, as: UTF8.self))
    if !response.ok { exit(1) }
} catch {
    FileHandle.standardError.write(Data("personalvpnctl: \(Redactor.redact(error.localizedDescription))\n".utf8))
    exit(1)
}
