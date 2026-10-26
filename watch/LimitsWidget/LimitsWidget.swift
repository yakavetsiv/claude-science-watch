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
            // fixedSize: faces render accessory text larger than in the
            // gallery, and fixed frames truncated it to "...".
            Text(name)
                .font(.caption2.weight(.semibold))
                .fixedSize()
            Gauge(value: limit?.fraction ?? 0) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(limit.map(LimitColor.color(for:)) ?? .gray)
            Text(percentText(limit))
                .font(.caption2.monospacedDigit())
                .fixedSize()
        }
    }
}

/// Two concentric rings: outer is the 5-hour limit, inner is the weekly
/// limit. Only the 5-hour percentage is printed in the middle.
struct ConcentricRings: View {
    let fiveHour: UsageLimit?
    let weekly: UsageLimit?

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let line = size * 0.12
            let gap = size * 0.04
            ZStack {
                ring(fiveHour?.fraction ?? 0, tint: outerTint, line: line)
                    .padding(line / 2)
                ring(weekly?.fraction ?? 0, tint: innerTint, line: line)
                    .padding(line * 1.5 + gap)
                Text(fiveHour.map { "\(Int($0.percent.rounded()))" } ?? "–")
                    .font(.system(size: size * 0.3, weight: .semibold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.5)
                    .padding(line * 2.5 + gap)
            }
            .frame(width: size, height: size)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    private var outerTint: Color {
        fiveHour.map(LimitColor.color(for:)) ?? .gray
    }

    /// Cyan keeps the weekly ring apart from the green 5-hour ring until it
    /// gets high enough to warn.
    private var innerTint: Color {
        guard let weekly else { return .gray }
        return weekly.percent >= 75 ? LimitColor.color(for: weekly) : .cyan
    }

    private func ring(_ fraction: Double, tint: Color, line: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.25), lineWidth: line)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
        }
    }
}

/// Circular: the concentric rings alone. Rectangular: rings plus reset times.
struct LimitRingsView: View {
    let entry: LimitsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let fiveHour = entry.status?.fiveHour
        let weekly = entry.status?.weekly

        switch family {
        case .accessoryRectangular:
            HStack(spacing: 8) {
                ConcentricRings(fiveHour: fiveHour, weekly: weekly)
                    .aspectRatio(1, contentMode: .fit)
                VStack(alignment: .leading, spacing: 2) {
                    resetLine("5h", fiveHour)
                    resetLine("Wk", weekly)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        default:
            ConcentricRings(fiveHour: fiveHour, weekly: weekly)
        }
    }

    /// Reset as a short clock time ("7:59", "Thu"). A relative countdown is too
    /// long for the space next to the rings and would go stale between refreshes.
    @ViewBuilder
    private func resetLine(_ name: String, _ limit: UsageLimit?) -> some View {
        if let resetsAt = limit?.resetsAt {
            let soon = resetsAt.timeIntervalSinceNow < 20 * 3600
            let when = soon
                ? resetsAt.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                : resetsAt.formatted(.dateTime.weekday(.abbreviated))
            (Text("\(name) ").fontWeight(.semibold) + Text(when))
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        } else {
            Text(name).font(.caption2.weight(.semibold))
        }
    }
}

// MARK: - Widgets

struct LimitRingsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LimitRings", provider: LimitsProvider()) { entry in
            LimitRingsView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Limit rings")
        .description("Outer ring: 5-hour limit (shown in the middle). Inner ring: weekly limit.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

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
        LimitRingsWidget()
        BothLimitsWidget()
        FiveHourWidget()
        WeeklyWidget()
    }
}

#Preview("Rings", as: .accessoryRectangular) {
    LimitRingsWidget()
} timeline: {
    LimitsEntry(date: .now, status: .sample)
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
