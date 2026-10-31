import AppCore
import AppKit

extension MenuBarDelegate {
  func updateStatusTitle(_ budgetText: String) {
    budgetStatusText = budgetText
    let title = RateLimitDisplayFormatting.statusTitle(
      selection: menuBarRatioSelection(), budgetText: budgetText, response: latestRateLimits
    )
    // Only touch the button when the value actually changed; reassigning an
    // identical title forces a redraw of the menu-bar item, which reads as a blink.
    if appliedTitle != title {
      appliedTitle = title
      statusItem.button?.title = title
      statusItem.button?.setAccessibilityValue(title)
    }
    updateStatusIcon()
  }

  func menuBarPieSelection() -> [PieChartID] {
    PieChartSelection.normalized(currentState?.menuBarPieCharts ?? PieChartSelection.defaultSelection)
  }

  func menuBarRatioSelection() -> [PieChartID] {
    RatioTextSelection.normalized(currentState?.menuBarRatioLabels ?? RatioTextSelection.defaultSelection)
  }

  func refreshRateLimitsIfNeeded() async {
    guard menuBarPieSelection().contains(where: { $0 != .budget })
      || menuBarRatioSelection().contains(where: { $0 != .budget }) else { return }
    latestRateLimits = await rateLimitService.current()
    updateStatusTitle(budgetStatusText)
  }

  @objc func togglePieChart(_ sender: NSMenuItem) {
    guard let rawValue = sender.representedObject as? String, let id = PieChartID(rawValue: rawValue) else { return }
    Task {
      if await mutateState({ $0.menuBarPieCharts = PieChartSelection.toggled(id, in: $0.menuBarPieCharts) }) {
        updateStatusIcon()
      }
    }
  }

  @objc func toggleRatioLabel(_ sender: NSMenuItem) {
    guard let rawValue = sender.representedObject as? String, let id = PieChartID(rawValue: rawValue) else { return }
    Task {
      if await mutateState({ $0.menuBarRatioLabels = RatioTextSelection.toggled(id, in: $0.menuBarRatioLabels) }) {
        updateStatusTitle(budgetStatusText)
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
