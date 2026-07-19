import CryptoKit
import Foundation

struct DiagnosticSanitizer: Sendable {
    static let redaction = "[redacted]"

    func opaqueReference(for value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func safeTimestamp(_ value: String?) -> String? {
        guard let value else { return nil }
        let sanitized = sanitize(value, maximumUTF8ByteCount: 64)
        guard sanitized.range(
            of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$"#,
            options: .regularExpression
        ) != nil else {
            return "unknown"
        }
        return sanitized
    }

    func sanitize(_ value: String, maximumUTF8ByteCount: Int = 512) -> String {
        let scalarSafe = value.unicodeScalars.map { scalar -> String in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate,
                 .privateUse, .unassigned:
                return " "
            default:
                return String(scalar)
            }
        }.joined()

        var result = scalarSafe
        result = replacing(
            #"(?i)\b(?:authorization|proxy-authorization|cookie|set-cookie)\s*:\s*[^\r\n]+"#,
            in: result,
            with: Self.redaction
        )
        result = replacing(
            #"(?i)\b(?:password|passwd|pwd|token|api[_-]?key|secret|client[_-]?secret|access[_-]?token|refresh[_-]?token|auth)\s*[:=]\s*[^\s,;]+"#,
            in: result,
            with: Self.redaction
        )
        result = replacing(
            #"(?i)([?&](?:password|passwd|pwd|token|api[_-]?key|secret|client[_-]?secret|access[_-]?token|refresh[_-]?token|auth)=)[^&\s]+"#,
            in: result,
            with: "$1[redacted]"
        )
        result = replacing(#"(?i)\b[a-z][a-z0-9+.-]*://[^\s]+"#, in: result, with: "[url]")
        result = replacing(#"(?<![A-Za-z0-9])~/(?:[^\s]+)"#, in: result, with: "[path]")
        result = replacing(#"(?i)\b[A-Z]:\\[^\s]+"#, in: result, with: "[path]")
        result = replacing(
            #"(?<![A-Za-z0-9])/(?:Users|home|private|tmp|var|Volumes|opt|usr|etc)(?:/[^\s]*)?"#,
            in: result,
            with: "[path]"
        )
        result = result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return truncateUTF8(result, maximumByteCount: max(0, maximumUTF8ByteCount))
    }

    func truncateUTF8(_ value: String, maximumByteCount: Int) -> String {
        guard maximumByteCount > 0 else { return "" }
        guard value.utf8.count > maximumByteCount else { return value }
        var result = ""
        result.reserveCapacity(min(value.count, maximumByteCount))
        for character in value {
            let candidate = result + String(character)
            guard candidate.utf8.count <= maximumByteCount else { break }
            result = candidate
        }
        return result
    }

    private func replacing(_ pattern: String, in value: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: replacement
        )
    }
}
