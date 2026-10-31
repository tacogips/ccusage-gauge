import AppCore
import AppKit
import Foundation

enum RateLimitMenuView {
  @MainActor static func items(selection: [PieChartID], response: RateLimitsResponse?, now: Date) -> [NSMenuItem] {
    PieChartID.allCases.filter { $0 != .budget && selection.contains($0) }.map { chart in
      let item = NSMenuItem(title: RateLimitDisplayFormatting.menuLine(for: chart, response: response, now: now), action: nil, keyEquivalent: "")
      item.isEnabled = false
      return item
    }
  }
}
