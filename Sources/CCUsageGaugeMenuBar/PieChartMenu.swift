import AppCore
import AppKit

enum PieChartMenu {
  @MainActor static func ratioTextItem(selection: [PieChartID], costOnly: Bool, target: AnyObject, action: Selector, costAction: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: "Ratio text", action: nil, keyEquivalent: "")
    let submenu = NSMenu()
    submenu.autoenablesItems = false
    let cost = NSMenuItem(title: "Cost only", action: costAction, keyEquivalent: "")
    cost.target = target
    cost.state = selection.contains(.budget) && costOnly ? .on : .off
    submenu.addItem(cost)
    for id in PieChartID.menuBarCases {
      let child = NSMenuItem(title: id == .budget ? "Cost and budget ratio" : RateLimitDisplayFormatting.title(for: id), action: action, keyEquivalent: "")
      child.target = target
      child.representedObject = id.rawValue
      child.state = selection.contains(id) && (id != .budget || !costOnly) ? .on : .off
      child.isEnabled = true
      submenu.addItem(child)
    }
    item.submenu = submenu
    return item
  }

  @MainActor static func item(selection: [PieChartID], target: AnyObject, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: "Usage icons", action: nil, keyEquivalent: "")
    let submenu = NSMenu()
    submenu.autoenablesItems = false
    for id in PieChartID.menuBarCases {
      let child = NSMenuItem(title: RateLimitDisplayFormatting.title(for: id), action: action, keyEquivalent: "")
      child.target = target
      child.representedObject = id.rawValue
      child.state = selection.contains(id) ? .on : .off
      child.isEnabled = !(selection.count == 1 && selection.contains(id))
      submenu.addItem(child)
    }
    item.submenu = submenu
    return item
  }
}
