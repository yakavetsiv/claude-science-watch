import SwiftUI

@main
struct ClaudeScienceWatchApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear { BackgroundRefresh.schedule() }
        }
        .backgroundTask(.appRefresh) { _ in
            await BackgroundRefresh.run()
        }
    }
}
