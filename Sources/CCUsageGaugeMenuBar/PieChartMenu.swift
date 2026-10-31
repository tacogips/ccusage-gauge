import AppCore
import AppKit

enum PieChartMenu {
  @MainActor static func item(selection: [PieChartID], target: AnyObject, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: "Pie charts", action: nil, keyEquivalent: "")
    let submenu = NSMenu()
    submenu.autoenablesItems = false
    for id in PieChartID.allCases {
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
