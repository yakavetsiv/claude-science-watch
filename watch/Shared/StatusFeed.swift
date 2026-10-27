import Foundation

/// Reads the latest status message the Mac helper published to ntfy.
enum StatusFeed {
    enum FeedError: LocalizedError {
        case notConfigured
        case noMessage
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "No status feed set. Add the relay or CSW_STATUS_TOPIC to Secrets.xcconfig."
            case .noMessage: "No status yet. Is the Mac helper running?"
            case .http(429): "ntfy's daily limit is used up. Answer in Claude Science until it resets."
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

    /// The relay Worker, when CSW_RELAY_URL and CSW_RELAY_TOKEN are set.
    /// It replaces ntfy for status and answers.
    private static var relay: (url: URL, token: String)? {
        func value(_ key: String) -> String? {
            guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
                  !value.isEmpty, !value.contains("$(") else { return nil }
            return value
        }
        guard let url = value("CSWRelayURL").flatMap(URL.init(string:)),
              let token = value("CSWRelayToken") else { return nil }
        return (url, token)
    }

    private static func relayRequest(_ path: String, method: String = "GET") -> URLRequest? {
        guard let relay else { return nil }
        var request = URLRequest(url: relay.url.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(relay.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// With `maxAge`, returns the cached status instead of going to the
    /// network when it was fetched that recently. The complications use it:
    /// four widget kinds refresh together and would otherwise fetch four times.
    static func fetchLatest(maxAge: TimeInterval) async throws -> UsageStatus {
        if let at = UserDefaults.standard.object(forKey: cacheDateKey) as? Date,
           Date.now.timeIntervalSince(at) < maxAge, let cached {
            return cached
        }
        return try await fetchLatest()
    }

    static func fetchLatest() async throws -> UsageStatus {
        let status = try await fetchFromNetwork()
        UserDefaults.standard.set(Date.now, forKey: cacheDateKey)
        return status
    }

    private static let cacheDateKey = "lastStatusFetchedAt"

    private static func fetchFromNetwork() async throws -> UsageStatus {
        if let request = relayRequest("status") {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 404 { throw FeedError.noMessage }
                if http.statusCode != 200 { throw FeedError.http(http.statusCode) }
            }
            let status = try decoder.decode(UsageStatus.self, from: data)
            UserDefaults.standard.set(data, forKey: cacheKey)
            return status
        }

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

    /// allow: this request only. allowConversation: this tool for the rest of
    /// the conversation. deny: refuse it.
    enum Decision: String {
        case allow
        case allowConversation = "allow_conversation"
        case deny
    }

    /// Posts an Allow/Deny answer to the helper's reply topic. The helper
    /// checks the one-time code and forwards it to Claude Science.
    static func answer(_ approval: Approval, _ decision: Decision, replyTopic: String?) async throws {
        var request: URLRequest
        if let relayRequest = relayRequest("reply", method: "POST") {
            request = relayRequest
        } else {
            let topic = replyTopic ?? topic.map { $0.replacingOccurrences(of: "-status", with: "-reply") }
            guard let topic, let url = URL(string: "\(server)/\(topic)") else { throw FeedError.notConfigured }
            request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
        }
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
