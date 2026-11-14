import Foundation

/// Best-effort source metadata for the session request most recently
/// recorded by the JetKVM device. Current firmware sends
/// `otherSessionConnected` with no params, so this is correlated from the
/// device's per-source Prometheus metric immediately after that event.
public struct TakeoverPeer: Equatable, Sendable {
    /// `local` for a direct connection, `cloud` for a JetKVM cloud session.
    /// Kept as a string so newer firmware source types remain displayable.
    public let sourceType: String
    /// For a local connection this is the peer IP reported by the device.
    /// For cloud connections it is the cloud gateway host, not the end user.
    public let source: String
    /// Device-reported Unix timestamp for the signaling request.
    public let requestTimestamp: TimeInterval

    public init(sourceType: String, source: String, requestTimestamp: TimeInterval) {
        self.sourceType = sourceType
        self.source = source
        self.requestTimestamp = requestTimestamp
    }
}

/// Minimal Prometheus text parser scoped to the one metric used for takeover
/// attribution. Supporting both names keeps this useful on firmware from
/// before and after JetKVM's June 2025 Prometheus naming cleanup.
enum TakeoverPeerMetricsParser {
    private static let metricNames: Set<Substring> = [
        "jetkvm_connection_last_session_request_timestamp",
        "jetkvm_connection_last_session_request_timestamp_seconds",
    ]

    static func latestPeer(in data: Data) -> TakeoverPeer? {
        let text = String(decoding: data, as: UTF8.self)
        var latest: TakeoverPeer?

        for rawLine in text.split(whereSeparator: \Character.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let openBrace = line.firstIndex(of: "{"),
                  let closeBrace = line[openBrace...].firstIndex(of: "}")
            else { continue }

            let name = line[..<openBrace]
            guard metricNames.contains(name) else { continue }

            let labelsText = line[line.index(after: openBrace)..<closeBrace]
            guard let labels = parseLabels(labelsText),
                  let sourceType = labels["type"],
                  let source = labels["source"]
            else { continue }

            let valueText = line[line.index(after: closeBrace)...]
                .split(whereSeparator: \Character.isWhitespace)
                .first
            guard let valueText,
                  let timestamp = TimeInterval(valueText),
                  timestamp.isFinite,
                  timestamp >= 0
            else { continue }

            let candidate = TakeoverPeer(
                sourceType: sourceType,
                source: source,
                requestTimestamp: timestamp
            )
            if latest.map({ timestamp > $0.requestTimestamp }) ?? true {
                latest = candidate
            }
        }

        return latest
    }

    /// Parse Prometheus labels, including its quoted-value escapes. This is
    /// intentionally small but does not assume label order.
    private static func parseLabels(_ text: Substring) -> [String: String]? {
        var labels: [String: String] = [:]
        var index = text.startIndex

        func skippingWhitespace(from start: Substring.Index) -> Substring.Index {
            var i = start
            while i < text.endIndex, text[i].isWhitespace {
                i = text.index(after: i)
            }
            return i
        }

        while true {
            index = skippingWhitespace(from: index)
            if index == text.endIndex { return labels }

            let keyStart = index
            while index < text.endIndex, text[index] != "=" {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { return nil }
            let key = text[keyStart..<index].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }

            index = text.index(after: index)
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex, text[index] == "\"" else { return nil }
            index = text.index(after: index)

            var value = ""
            var closed = false
            while index < text.endIndex {
                let character = text[index]
                index = text.index(after: index)
                if character == "\"" {
                    closed = true
                    break
                }
                if character == "\\" {
                    guard index < text.endIndex else { return nil }
                    let escaped = text[index]
                    index = text.index(after: index)
                    switch escaped {
                    case "n": value.append("\n")
                    case "\\": value.append("\\")
                    case "\"": value.append("\"")
                    default: value.append(escaped)
                    }
                } else {
                    value.append(character)
                }
            }
            guard closed else { return nil }
            labels[key] = value

            index = skippingWhitespace(from: index)
            if index == text.endIndex { return labels }
            guard text[index] == "," else { return nil }
            index = text.index(after: index)
        }
    }
}
