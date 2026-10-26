import SwiftUI
import WidgetKit

struct ContentView: View {
    @State private var status: UsageStatus? = StatusFeed.cached
    @State private var error: String?
    @State private var loading = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                if let status {
                    let current = status.asOf(.now)
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
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    /// The helper publishes at least every 30 minutes while the Mac is awake.
    private func isStale(_ status: UsageStatus) -> Bool {
        Date.now.timeIntervalSince(status.updatedAt) > 45 * 60
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
