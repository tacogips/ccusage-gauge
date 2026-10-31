import AppCore
import AppKit

extension MenuBarDelegate {
  func menuBarPieSelection() -> [PieChartID] {
    PieChartSelection.normalized(currentState?.menuBarPieCharts ?? PieChartSelection.defaultSelection)
  }

  func refreshRateLimitsIfNeeded() async {
    guard menuBarPieSelection().contains(where: { $0 != .budget }) else { return }
    latestRateLimits = await rateLimitService.current()
    updateStatusIcon()
  }

  @objc func togglePieChart(_ sender: NSMenuItem) {
    guard let rawValue = sender.representedObject as? String, let id = PieChartID(rawValue: rawValue) else { return }
    Task {
      if await mutateState({ $0.menuBarPieCharts = PieChartSelection.toggled(id, in: $0.menuBarPieCharts) }) {
        updateStatusIcon()
      }
    }
  }

  func pieEntries() -> [MenuBarPieEntry] {
    menuBarPieSelection().map { id in
      if id == .budget {
        return .budget(
          fraction: latestSnapshot?.budget.visualFraction,
          hasBudget: currentState?.budgetUSD != nil,
          warning: isUsageUnavailable || !collectionWarnings.isEmpty
        )
      }
      let window = RateLimitDisplayFormatting.entry(for: id, in: latestRateLimits).window
      return .rateLimit(fraction: RateLimitDisplayFormatting.pieFraction(window))
    }
  }

  func pieAccessibilityDescription() -> String {
    menuBarPieSelection().map { id in
      guard id != .budget else { return "Budget" }
      let title = RateLimitDisplayFormatting.title(for: id)
      let window = RateLimitDisplayFormatting.entry(for: id, in: latestRateLimits).window
      guard let fraction = RateLimitDisplayFormatting.pieFraction(window) else { return "\(title) unavailable" }
      return "\(title) \(Int((fraction * 100).rounded()))% used"
    }.joined(separator: ", ")
  }
}
