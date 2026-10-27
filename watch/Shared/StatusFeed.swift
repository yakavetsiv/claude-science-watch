import Foundation

/// Reads the latest status message the Mac helper published to ntfy.
enum StatusFeed {
    enum FeedError: LocalizedError {
        case notConfigured
        case noMessage
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "No status topic set. Add CSW_STATUS_TOPIC to Secrets.xcconfig."
            case .noMessage: "No status yet. Is the Mac helper running?"
            case .http(let code): "ntfy returned HTTP \(code)."
            }
        }
    }

    private static let cacheKey = "lastStatus"

    static var topic: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CSWStatusTopic") as? String,
              !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    static var server: String {
        (Bundle.main.object(forInfoDictionaryKey: "CSWNtfyServer") as? String) ?? "https://ntfy.sh"
    }

    static func fetchLatest() async throws -> UsageStatus {
        guard let topic,
              let url = URL(string: "\(server)/\(topic)/json?poll=1&since=latest") else {
            throw FeedError.notConfigured
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FeedError.http(http.statusCode)
        }

        // ntfy returns one JSON object per line; the status is the `message`
        // string of the last "message" event.
        struct Event: Decodable {
            let event: String
            let message: String?
        }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        let message = lines.reversed().lazy
            .compactMap { try? JSONDecoder().decode(Event.self, from: Data($0.utf8)) }
            .first { $0.event == "message" }?.message
        guard let message else { throw FeedError.noMessage }

        let status = try decoder.decode(UsageStatus.self, from: Data(message.utf8))
        UserDefaults.standard.set(Data(message.utf8), forKey: cacheKey)
        return status
    }

    enum Decision: String { case allow, deny }

    /// Posts an Allow/Deny answer to the helper's reply topic. The helper
    /// checks the one-time code and forwards it to Claude Science.
    static func answer(_ approval: Approval, _ decision: Decision, replyTopic: String?) async throws {
        let topic = replyTopic ?? topic.map { $0.replacingOccurrences(of: "-status", with: "-reply") }
        guard let topic, let url = URL(string: "\(server)/\(topic)") else { throw FeedError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "id": approval.id, "nonce": approval.nonce, "decision": decision.rawValue,
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FeedError.http(http.statusCode)
        }
    }

    /// Last status fetched by this process (app and widget each keep their own).
    static var cached: UsageStatus? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? decoder.decode(UsageStatus.self, from: data)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
                return date
            }
            if let date = try? Date.ISO8601FormatStyle().parse(string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Bad date \(string)"))
        }
        return decoder
    }()
}
