import SwiftUI
import WidgetKit

struct ContentView: View {
    @State private var status: UsageStatus? = StatusFeed.cached
    @State private var error: String?
    @State private var loading = false
    @State private var remindersSet = 0
    /// Approvals answered from this watch, hidden until the helper's next
    /// status drops them.
    @State private var answered: Set<String> = []
    @State private var sending: String?
    @AppStorage(ExpiryReminder.enabledKey) private var remindersEnabled = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                if let status {
                    let current = status.asOf(.now)
                    let waiting = (status.approvals ?? []).filter { !answered.contains($0.id) }
                    if !waiting.isEmpty {
                        Section("Needs permission") {
                            ForEach(waiting) { approval in
                                ApprovalRow(approval: approval, sending: sending == approval.id,
                                            isPrimary: approval.id == waiting.first?.id) { decision in
                                    Task { await answer(approval, decision, replyTopic: status.replyTopic) }
                                }
                            }
                        }
                    }
                    if let limit = current.fiveHour {
                        LimitRow(title: "5-hour", limit: limit)
                    }
                    if let limit = current.weekly {
                        LimitRow(title: "Weekly", limit: limit)
                    }
                    ForEach(current.limits.filter { $0.kind == "weekly_scoped" && $0.percent > 0 }) { limit in
                        LimitRow(title: limit.label.replacingOccurrences(of: "Weekly limit", with: "Weekly"),
                                 limit: limit)
                    }
                    if let sessions = status.sessions {
                        SessionsRow(sessions: sessions)
                    }
                    Section {
                        Text("Updated \(status.updatedAt, style: .relative) ago")
                            .font(.footnote)
                            .foregroundStyle(isStale(status) ? .orange : .secondary)
                    }
                } else if !loading {
                    Text(error ?? "No data yet.")
                        .foregroundStyle(.secondary)
                }
                if let error, status != nil {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if let expiry = ExpiryReminder.expirationDate {
                    Section {
                        Toggle("Expiry reminders", isOn: $remindersEnabled)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Install expires \(expiry.formatted(date: .abbreviated, time: .shortened))")
                            if remindersEnabled {
                                Text(remindersSet > 0 ? "Reminders 24 h and 1 h before" : "Notifications not allowed")
                                    .foregroundStyle(remindersSet > 0 ? Color.secondary : Color.orange)
                            }
                        }
                        .font(.footnote)
                    }
                }
            }
            .navigationTitle("Claude Science")
            .overlay {
                if loading && status == nil { ProgressView() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(loading)
                }
            }
        }
        .task {
            remindersSet = await ExpiryReminder.schedule()
            await refresh()
        }
        .onChange(of: remindersEnabled) {
            Task { remindersSet = await ExpiryReminder.schedule() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    /// The helper publishes at least every 30 minutes while the Mac is awake.
    private func isStale(_ status: UsageStatus) -> Bool {
        Date.now.timeIntervalSince(status.updatedAt) > 45 * 60
    }

    private func answer(_ approval: Approval, _ decision: StatusFeed.Decision, replyTopic: String?) async {
        sending = approval.id
        defer { sending = nil }
        do {
            try await StatusFeed.answer(approval, decision, replyTopic: replyTopic)
            answered.insert(approval.id)
            error = nil
            // The helper applies the answer and republishes status within a poll.
            try? await Task.sleep(for: .seconds(35))
            await refresh()
        } catch {
            self.error = "Answer not sent: \(error.localizedDescription)"
        }
    }

    private func refresh() async {
        loading = true
        defer { loading = false }
        do {
            let latest = try await StatusFeed.fetchLatest()
            if latest != status {
                status = latest
                WidgetCenter.shared.reloadAllTimelines()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct LimitRow: View {
    let title: String
    let limit: UsageLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("\(Int(limit.percent.rounded()))%")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(LimitColor.color(for: limit))
            }
            Gauge(value: limit.fraction) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(LimitColor.color(for: limit))
            if let resetsAt = limit.resetsAt {
                Text("Resets in \(resetsAt, style: .relative)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ApprovalRow: View {
    let approval: Approval
    let sending: Bool
    /// The first waiting request: a double tap presses its Allow button.
    let isPrimary: Bool
    let onAnswer: (StatusFeed.Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(approval.title, systemImage: "lock.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            if let session = approval.session {
                Text([approval.project, session].compactMap { $0 }.joined(separator: ": "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let detail = approval.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(3)
            }
            if sending {
                ProgressView()
            } else {
                HStack {
                    Button("Allow") { onAnswer(.allow) }
                        .tint(.green)
                        .handGestureShortcut(.primaryAction, isEnabled: isPrimary)
                    Button("Deny", role: .destructive) { onAnswer(.deny) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SessionsRow: View {
    let sessions: SessionCounts

    var body: some View {
        HStack {
            Label("\(sessions.processing) running", systemImage: "gearshape.2")
            Spacer()
            if sessions.needsInput > 0 {
                Label("\(sessions.needsInput)", systemImage: "hand.raised.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.footnote)
    }
}

#Preview {
    ContentView()
}
