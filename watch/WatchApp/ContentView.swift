import SwiftUI
import WatchKit
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
                    ForEach(waiting) { approval in
                        ApprovalSection(approval: approval, sending: sending == approval.id,
                                        isPrimary: approval.id == waiting.first?.id,
                                        showsHeader: approval.id == waiting.first?.id) { decision in
                            Task { await answer(approval, decision, replyTopic: status.replyTopic) }
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
                        SessionsSection(sessions: sessions)
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
        // While the app is on screen (including wrist-down Always On),
        // check every 10 seconds so new requests buzz almost at once.
        .task(id: scenePhase) {
            guard scenePhase != .background else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled { await refresh() }
            }
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
            WKInterfaceDevice.current().play(.failure)
        }
    }

    /// Buzzes when requests appear or clear between two statuses: a
    /// notification tap for a new request, a success tap when one this watch
    /// answered is gone (the helper applied it).
    private func playHaptics(from old: UsageStatus?, to new: UsageStatus) {
        let before = Set((old?.approvals ?? []).map(\.id))
        let after = Set((new.approvals ?? []).map(\.id))
        if !after.subtracting(before).isEmpty {
            WKInterfaceDevice.current().play(.notification)
        } else if !before.subtracting(after).intersection(answered).isEmpty {
            WKInterfaceDevice.current().play(.success)
        }
    }

    private func refresh() async {
        #if DEBUG
        // `-demoApprovals` (simulator screenshots) shows a sample request
        // without touching the real feed.
        if ProcessInfo.processInfo.arguments.contains("-demoApprovals") {
            status = .sampleNeedsYou
            return
        }
        #endif
        loading = true
        defer { loading = false }
        do {
            let latest = try await StatusFeed.fetchLatest()
            if latest != status {
                playHaptics(from: status, to: latest)
                answered.formIntersection((latest.approvals ?? []).map(\.id))
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
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(limit.percent.rounded()))%")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(LimitColor.color(for: limit))
            }
            Gauge(value: limit.fraction) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(LimitColor.color(for: limit))
            if let resetsAt = limit.resetsAt {
                Text("Resets in \(resetsAt, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One permission request: a card with what is asked, then full-width Allow
/// and Deny buttons. All three share one row so their edges line up.
struct ApprovalSection: View {
    let approval: Approval
    let sending: Bool
    /// The first waiting request: a double tap presses its Allow button.
    let isPrimary: Bool
    let showsHeader: Bool
    let onAnswer: (StatusFeed.Decision) -> Void

    var body: some View {
        Section {
            VStack(spacing: 8) {
                card
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                if sending {
                    HStack(spacing: 8) {
                        ProgressView().frame(width: 20, height: 20)
                        Text("Sending…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    answerButton("Allow", icon: "checkmark", decision: .allow, tint: .green)
                        .handGestureShortcut(.primaryAction, isEnabled: isPrimary)
                    answerButton("Deny", icon: "xmark", decision: .deny, tint: .red)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } header: {
            if showsHeader {
                Text("Needs permission").foregroundStyle(.orange)
            }
        } footer: {
            if isPrimary && !sending {
                Label("Double tap to allow", systemImage: "hand.tap")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // Sizes follow the system apps: body for the main line, footnote and
    // caption for secondary text, small monospaced code.
    private var card: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text(approval.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }
            if let session = approval.session {
                Text([approval.project, session].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let detail = approval.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(4)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 2)
            }
        }
    }

    /// Allow is the filled, primary button. Deny is a quieter grey button
    /// with red text, so the two are easy to tell apart at a glance.
    private func answerButton(_ title: String, icon: String, decision: StatusFeed.Decision,
                              tint: Color) -> some View {
        Button { onAnswer(decision) } label: {
            Label(title, systemImage: icon)
        }
        .buttonStyle(PillButtonStyle(
            fill: decision == .allow ? tint : .white.opacity(0.14),
            text: decision == .allow ? .black : tint
        ))
    }
}

/// Full-width capsule button that spans exactly the width it is given, so it
/// lines up with the card above (system bordered buttons add their own inset).
struct PillButtonStyle: ButtonStyle {
    let fill: Color
    let text: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.semibold))
            .foregroundStyle(text)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(fill, in: Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Capsule())
    }
}

/// Sessions waiting on you, then sessions working now, by name. Falls back
/// to counts when the helper sends no names (`includeNames` off).
struct SessionsSection: View {
    let sessions: SessionCounts

    var body: some View {
        Section("Sessions") {
            if let running = sessions.running {
                let waiting = sessions.waiting ?? []
                ForEach(Array(waiting.enumerated()), id: \.offset) { _, session in
                    SessionRow(session: session, icon: "hand.raised.fill", tint: .orange)
                }
                ForEach(Array(running.enumerated()), id: \.offset) { _, session in
                    SessionRow(session: session, icon: "gearshape.2.fill", tint: .green)
                }
                if running.isEmpty && waiting.isEmpty {
                    Text("Nothing running")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
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
    }
}

struct SessionRow: View {
    let session: SessionName
    let icon: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: icon.hasPrefix("gearshape"))
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                if let project = session.project {
                    Text(project)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    ContentView()
}
