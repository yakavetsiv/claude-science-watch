import SwiftUI
import WidgetKit

// MARK: - Timeline

struct LimitsEntry: TimelineEntry {
    let date: Date
    let status: UsageStatus?
}

struct LimitsProvider: TimelineProvider {
    func placeholder(in context: Context) -> LimitsEntry {
        LimitsEntry(date: .now, status: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (LimitsEntry) -> Void) {
        if context.isPreview {
            completion(LimitsEntry(date: .now, status: .sample))
            return
        }
        Task {
            let status = (try? await StatusFeed.fetchLatest()) ?? StatusFeed.cached
            completion(LimitsEntry(date: .now, status: status))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LimitsEntry>) -> Void) {
        Task {
            let now = Date.now
            let status = (try? await StatusFeed.fetchLatest()) ?? StatusFeed.cached
            // One entry now, plus one at each reset so the gauge drops to 0 %
            // on time even if the next fetch is late.
            let dates = [now] + (status?.upcomingResets(after: now) ?? [])
            let entries = dates.map { LimitsEntry(date: $0, status: status?.asOf($0)) }
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
        }
    }
}

// MARK: - Views

/// Circular and corner complication for one limit.
struct SingleLimitView: View {
    let entry: LimitsEntry
    let kind: String
    let shortName: String
    @Environment(\.widgetFamily) private var family

    private var limit: UsageLimit? {
        entry.status?.limits.first { $0.kind == kind }
    }

    var body: some View {
        let fraction = limit?.fraction ?? 0
        let percent = limit.map { "\(Int($0.percent.rounded()))" } ?? "–"
        let tint = limit.map(LimitColor.color(for:)) ?? .gray

        switch family {
        case .accessoryCorner:
            Text("\(percent)%")
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .widgetCurvesContent()
                .widgetLabel {
                    Gauge(value: fraction) {
                        Text(shortName)
                    } currentValueLabel: {
                        Text(percent)
                    } minimumValueLabel: {
                        Text(shortName)
                    } maximumValueLabel: {
                        Text("")
                    }
                    .tint(tint)
                }
        default:
            Gauge(value: fraction) {
                Text(shortName)
            } currentValueLabel: {
                Text(percent)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint)
        }
    }
}

/// Rectangular and inline complication showing both limits.
struct BothLimitsView: View {
    let entry: LimitsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let fiveHour = entry.status?.fiveHour
        let weekly = entry.status?.weekly

        switch family {
        case .accessoryInline:
            Text("5h \(percentText(fiveHour)) · Wk \(percentText(weekly))")
        default:
            VStack(alignment: .leading, spacing: 2) {
                row("5h", fiveHour)
                row("Wk", weekly)
                if let resetsAt = fiveHour?.resetsAt {
                    (Text("5h resets in ") + Text(resetsAt, style: .relative))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Claude Science")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func percentText(_ limit: UsageLimit?) -> String {
        limit.map { "\(Int($0.percent.rounded()))%" } ?? "–"
    }

    private func row(_ name: String, _ limit: UsageLimit?) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.caption2.weight(.semibold))
                .frame(width: 18, alignment: .leading)
            Gauge(value: limit?.fraction ?? 0) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(limit.map(LimitColor.color(for:)) ?? .gray)
            Text(percentText(limit))
                .font(.caption2.monospacedDigit())
                .frame(width: 32, alignment: .trailing)
        }
    }
}

// MARK: - Widgets

struct FiveHourWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FiveHourLimit", provider: LimitsProvider()) { entry in
            SingleLimitView(entry: entry, kind: "session", shortName: "5h")
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("5-hour limit")
        .description("Claude Science 5-hour usage.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
    }
}

struct WeeklyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WeeklyLimit", provider: LimitsProvider()) { entry in
            SingleLimitView(entry: entry, kind: "weekly_all", shortName: "Wk")
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Weekly limit")
        .description("Claude Science weekly usage, all models.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
    }
}

struct BothLimitsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BothLimits", provider: LimitsProvider()) { entry in
            BothLimitsView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Claude limits")
        .description("5-hour and weekly Claude Science usage.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}

@main
struct LimitsWidgetBundle: WidgetBundle {
    var body: some Widget {
        BothLimitsWidget()
        FiveHourWidget()
        WeeklyWidget()
    }
}

#Preview("Rectangular", as: .accessoryRectangular) {
    BothLimitsWidget()
} timeline: {
    LimitsEntry(date: .now, status: .sample)
}

#Preview("Circular", as: .accessoryCircular) {
    FiveHourWidget()
} timeline: {
    LimitsEntry(date: .now, status: .sample)
}
