import CryptoKit
import Foundation
import Security

public final class SubscriptionFetcher: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let policy: SubscriptionTLSPolicy

    public init(policy: SubscriptionTLSPolicy) {
        self.policy = policy
    }

    public func fetch(from source: SubscriptionSource) async throws -> Data {
        guard let url = URL(string: source.url), url.scheme?.lowercased() == "https" else {
            throw PersonalVPNError.invalidSubscription("subscription URL must use HTTPS")
        }
        if case .pinnedSHA256(let fingerprint) = policy {
            let normalized = fingerprint.lowercased().filter(\.isHexDigit)
            guard normalized.count == 64 else {
                throw PersonalVPNError.invalidSubscription("certificate pin must contain exactly 64 hexadecimal characters")
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PersonalVPNError.invalidSubscription("subscription server returned a non-success status")
        }
        guard !data.isEmpty, data.count <= 10_000_000 else {
            throw PersonalVPNError.invalidSubscription("subscription response is empty or too large")
        }
        return data
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        switch policy {
        case .system:
            completionHandler(.performDefaultHandling, nil)
        case .pinnedSHA256(let expected):
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let certificate = chain.first else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
                .map { String(format: "%02x", $0) }.joined()
            let normalized = expected.lowercased().filter(\.isHexDigit)
            if digest == normalized {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}
