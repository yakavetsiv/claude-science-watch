import Foundation
import UserNotifications

/// Free (Personal Team) signing expires after 7 days. Reads the expiry date
/// from the installed app's provisioning profile and schedules local
/// notifications 24 hours and 1 hour before it, so there is time to redeploy.
enum ExpiryReminder {
    private static let leadTimes: [(id: String, seconds: TimeInterval, text: String)] = [
        ("expiry-24h", 24 * 3600, "in 24 hours"),
        ("expiry-1h", 3600, "in 1 hour"),
    ]

    /// Expiry of the profile this build was signed with. Nil in the simulator,
    /// which has no embedded profile.
    static var expirationDate: Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        // The profile is a signed CMS blob with the XML plist inside it.
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        return plist?["ExpirationDate"] as? Date
    }

    /// UserDefaults key for the in-app toggle. Reminders are on by default.
    static let enabledKey = "expiryRemindersEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: leadTimes.map(\.id))
    }

    /// Replaces any earlier reminders with ones for this build. Returns how
    /// many are pending (0 when the toggle is off).
    @discardableResult
    static func schedule() async -> Int {
        cancel()
        guard isEnabled, let expiry = expirationDate else { return 0 }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return 0 }

        var scheduled = 0
        for lead in leadTimes {
            let fireDate = expiry.addingTimeInterval(-lead.seconds)
            let interval = fireDate.timeIntervalSinceNow
            guard interval > 0 else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Claude Limits expires \(lead.text)"
            content.body = "Redeploy from Xcode before \(expiry.formatted(date: .abbreviated, time: .shortened)) to keep the app and complications working."
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: lead.id,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            )
            if (try? await center.add(request)) != nil { scheduled += 1 }
        }
        return scheduled
    }
}
