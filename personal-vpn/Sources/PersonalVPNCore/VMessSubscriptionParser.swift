import CryptoKit
import Foundation

public enum VMessSubscriptionParser {
    private struct Payload: Decodable {
        var ps: String?
        var add: String
        var port: FlexibleInt
        var id: String
        var aid: FlexibleInt?
        var scy: String?
        var net: String?
        var path: String?
        var host: String?
        var tls: String?
        var sni: String?
    }

    private enum FlexibleInt: Decodable {
        case value(Int)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int.self) {
                self = .value(value)
            } else if let string = try? container.decode(String.self), let value = Int(string) {
                self = .value(value)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an integer or numeric string")
            }
        }

        var intValue: Int {
            switch self { case .value(let value): value }
        }
    }

    public static func parse(data: Data, sourceID: String) throws -> [VMessNode] {
        let decoded: Data
        if let text = String(data: data, encoding: .utf8), text.contains("vmess://") {
            decoded = data
        } else {
            let compact = data.filter { ![9, 10, 13, 32].contains($0) }
            guard let value = Data(base64Encoded: compact, options: [.ignoreUnknownCharacters]) else {
                throw PersonalVPNError.invalidSubscription("The response is neither URI text nor Base64")
            }
            decoded = value
        }

        guard let content = String(data: decoded, encoding: .utf8) else {
            throw PersonalVPNError.invalidSubscription("The decoded response is not UTF-8")
        }

        var nodes: [VMessNode] = []
        var seen = Set<String>()
        for line in content.split(whereSeparator: \Character.isNewline) {
            let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            guard value.hasPrefix("vmess://") else { continue }
            let encoded = String(value.dropFirst("vmess://".count))
            guard let payloadData = decodeBase64(encoded) else { continue }
            let payload: Payload
            do {
                payload = try JSONDecoder().decode(Payload.self, from: payloadData)
            } catch {
                continue
            }

            guard !payload.add.isEmpty, !payload.id.isEmpty, payload.port.intValue > 0, payload.port.intValue <= 65_535 else { continue }
            let stableIdentity = "\(sourceID)|\(payload.add)|\(payload.port.intValue)|\(payload.id)"
            let nodeID = SHA256.hash(data: Data(stableIdentity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            guard seen.insert(nodeID).inserted else { continue }
            nodes.append(VMessNode(
                id: nodeID,
                sourceID: sourceID,
                name: payload.ps?.isEmpty == false ? payload.ps! : payload.add,
                host: payload.add,
                port: payload.port.intValue,
                uuid: payload.id,
                alterID: payload.aid?.intValue ?? 0,
                security: payload.scy ?? "auto",
                network: payload.net ?? "tcp",
                path: payload.path ?? "",
                headerHost: payload.host ?? "",
                tlsEnabled: ["tls", "1", "true"].contains((payload.tls ?? "").lowercased()),
                serverName: payload.sni ?? payload.host ?? ""
            ))
        }

        guard !nodes.isEmpty else {
            throw PersonalVPNError.invalidSubscription("No valid VMess nodes were found")
        }
        return nodes
    }

    private static func decodeBase64(_ input: String) -> Data? {
        var normalized = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: normalized, options: [.ignoreUnknownCharacters])
    }
}
