import Foundation

/// One plan limit, as published by the Mac helper (`status.json`).
struct UsageLimit: Codable, Hashable, Identifiable {
    let kind: String
    let label: String
    let percent: Double
    let severity: String?
    let resetsAt: Date?

    var id: String { kind }

    /// Fraction used, 0...1, for gauges.
    var fraction: Double { min(max(percent / 100, 0), 1) }

    /// After the reset time passes, the helper's last value is stale; the
    /// limit has started over.
    func asOf(_ date: Date) -> UsageLimit {
        guard let resetsAt, resetsAt <= date else { return self }
        return UsageLimit(kind: kind, label: label, percent: 0, severity: "normal", resetsAt: nil)
    }
}

struct SessionCounts: Codable, Hashable {
    let processing: Int
    let needsInput: Int
}

/// A permission request waiting in Claude Science, as relayed by the helper.
struct Approval: Codable, Hashable, Identifiable {
    let id: String
    /// One-time code the helper checks when the answer comes back.
    let nonce: String
    let title: String
    let detail: String?
    let project: String?
    let session: String?
    let createdAt: Date?
}

struct UsageStatus: Codable, Hashable {
    let updatedAt: Date
    let limits: [UsageLimit]
    let sessions: SessionCounts?
    var approvals: [Approval]? = nil
    var replyTopic: String? = nil

    /// A session is waiting on the user: a permission request or a question.
    var needsAttention: Bool {
        !(approvals ?? []).isEmpty || (sessions?.needsInput ?? 0) > 0
    }

    /// Short reason for the complication, such as "Run python?".
    var attentionText: String? {
        if let first = approvals?.first { return "\(first.title)?" }
        return needsAttention ? "Needs input" : nil
    }

    var fiveHour: UsageLimit? { limits.first { $0.kind == "session" } }
    var weekly: UsageLimit? { limits.first { $0.kind == "weekly_all" } }

    func asOf(_ date: Date) -> UsageStatus {
        UsageStatus(updatedAt: updatedAt, limits: limits.map { $0.asOf(date) }, sessions: sessions,
                    approvals: approvals, replyTopic: replyTopic)
    }

    /// Reset times still ahead of `date`, so a widget timeline can show the
    /// drop to 0 % without waiting for the next fetch.
    func upcomingResets(after date: Date) -> [Date] {
        Set(limits.compactMap(\.resetsAt)).filter { $0 > date }.sorted()
    }

    static let sample = UsageStatus(
        updatedAt: .now,
        limits: [
            UsageLimit(kind: "session", label: "5-hour limit", percent: 34, severity: "normal",
                       resetsAt: .now.addingTimeInterval(2 * 3600)),
            UsageLimit(kind: "weekly_all", label: "Weekly limit (all models)", percent: 61, severity: "normal",
                       resetsAt: .now.addingTimeInterval(3 * 86400)),
        ],
        sessions: SessionCounts(processing: 1, needsInput: 0)
    )

    static let sampleNeedsYou = UsageStatus(
        updatedAt: .now,
        limits: sample.limits,
        sessions: SessionCounts(processing: 0, needsInput: 1),
        approvals: [Approval(id: "sample", nonce: "", title: "Run python", detail: "import numpy as np",
                             project: "Example project", session: "Test", createdAt: .now)]
    )
}
