import SwiftUI

enum LimitColor {
    static func color(for limit: UsageLimit) -> Color {
        switch limit.percent {
        case 90...: .red
        case 75..<90: .orange
        default: .green
        }
    }
}
