import AppCore
import AppKit

extension MenuBarDelegate {
  func updateStatusTitle(_ budgetText: String) {
    budgetStatusText = budgetText
    let title = menuBarRatioSelection().contains(.budget) ? budgetText : ""
    if appliedTitle != title {
      appliedTitle = title
      statusItem.button?.title = title
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
      if await mutateState({ state in
        if id == .budget && state.menuBarCostOnly {
          state.menuBarCostOnly = false
          state.menuBarRatioLabels = RatioTextSelection.normalized(state.menuBarRatioLabels + [.budget])
        } else {
          state.menuBarRatioLabels = RatioTextSelection.toggled(id, in: state.menuBarRatioLabels)
        }
      }) {
        updateStatusTitle(budgetStatusText)
      }
    }
  }

  @objc func toggleCostOnly() {
    Task {
      if await mutateState({ state in
        if state.menuBarCostOnly && state.menuBarRatioLabels.contains(.budget) {
          state.menuBarRatioLabels = RatioTextSelection.toggled(.budget, in: state.menuBarRatioLabels)
        } else {
          state.menuBarCostOnly = true
          state.menuBarRatioLabels = RatioTextSelection.normalized(state.menuBarRatioLabels + [.budget])
        }
      }) {
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

  func statusEntries() -> [MenuBarStatusEntry] {
    let pies = menuBarPieSelection()
    let ratios = menuBarRatioSelection()
    let pieByID = Dictionary(uniqueKeysWithValues: zip(pies, pieEntries()))
    return PieChartID.allCases.compactMap { id in
      var ratio: String?
      if ratios.contains(id) {
        if id == .budget {
          if currentState?.menuBarCostOnly != true, let value = latestSnapshot?.budget.usagePercentage {
            let formatter = NumberFormatter()
            formatter.maximumFractionDigits = 1
            ratio = "\(formatter.string(from: value as NSDecimalNumber) ?? String(describing: value))%"
          }
        } else {
          ratio = RateLimitDisplayFormatting.ratioLabel(for: id, in: latestRateLimits)
        }
      }
      guard let pie = pieByID[id] else {
        return ratio.map {
          let fraction = RateLimitDisplayFormatting.entry(for: id, in: latestRateLimits).window?.pieFraction
          let indicator: MenuBarPieEntry? = id == .budget ? nil : .rateLimit(fraction: fraction)
          return MenuBarStatusEntry(chart: id, pie: indicator, ratio: $0)
        }
      }
      return MenuBarStatusEntry(chart: id, pie: pie, ratio: ratio)
    }
  }

  /// Hover text: selected usage, ratio text, then any active extended usage (credits).
  func statusToolTip(accessibility: String, ratioDescription: String) -> String {
    let credits = RateLimitDisplayFormatting.creditLines(response: latestRateLimits, now: Date())
    return (["ccusage-gauge", accessibility, ratioDescription, appliedTitle ?? ""] + credits)
      .filter { !$0.isEmpty }.joined(separator: "\n")
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
