import Foundation
import WatchKit
import WidgetKit

/// Background status checks. watchOS wakes the app roughly every 15-30
/// minutes (more often while a complication is on the active face). Each wake
/// fetches the status and reloads the complications only if it changed, so
/// the refresh budget goes on real changes.
enum BackgroundRefresh {
    static let interval: TimeInterval = 15 * 60

    static func schedule() {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(interval),
            userInfo: nil
        ) { _ in }
    }

    static func run() async {
        defer { schedule() }
        let before = StatusFeed.cached
        guard let latest = try? await StatusFeed.fetchLatest() else { return }
        if latest != before {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
