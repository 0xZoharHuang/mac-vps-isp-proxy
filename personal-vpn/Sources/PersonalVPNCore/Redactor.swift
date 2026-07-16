import Foundation

public enum Redactor {
    private static let sensitiveKeys = ["token", "password", "passwd", "private_key", "privateKey", "uuid"]

    public static func redact(_ input: String) -> String {
        var output = input
        for key in sensitiveKeys {
            let patterns = [
                "(?i)(\"?\(NSRegularExpression.escapedPattern(for: key))\"?\\s*[:=]\\s*\")([^\"]+)(\")",
                "(?i)([?&]\(NSRegularExpression.escapedPattern(for: key))=)([^&\\s]+)",
            ]
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(output.startIndex..<output.endIndex, in: output)
                output = regex.stringByReplacingMatches(in: output, range: range, withTemplate: "$1<redacted>$3")
            }
        }
        return output
    }
}
