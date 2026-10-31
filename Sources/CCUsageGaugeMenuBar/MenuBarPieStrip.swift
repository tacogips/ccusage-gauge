import AppKit
import Foundation

enum MenuBarPieEntry: Equatable {
  case budget(fraction: Decimal?, hasBudget: Bool, warning: Bool)
  case rateLimit(fraction: Double?)
}

enum MenuBarPieStrip {
  static func image(entries: [MenuBarPieEntry], accessibilityDescription: String) -> NSImage {
    if entries.count == 1, case let .budget(fraction, hasBudget, warning) = entries[0] {
      return MenuBarPieIcon.image(fraction: fraction, hasBudget: hasBudget, warning: warning)
    }
    let width = max(0, entries.count * 18 + max(0, entries.count - 1) * 2)
    let image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { _ in
      for (index, entry) in entries.enumerated() {
        let bounds = NSRect(x: index * 20, y: 0, width: 18, height: 18)
        switch entry {
        case let .budget(fraction, hasBudget, warning):
          MenuBarPieIcon.image(fraction: fraction, hasBudget: hasBudget, warning: warning).draw(in: bounds)
        case let .rateLimit(fraction):
          let circle = bounds.insetBy(dx: 2, dy: 2)
          MenuBarPieIcon.drawRail(circle: circle)
          if let fraction {
            MenuBarPieIcon.drawUsedWedge(fraction: Decimal(fraction), circle: circle)
          } else {
            MenuBarPieIcon.drawBudgetMarker(circle: circle)
          }
        }
      }
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = accessibilityDescription
    return image
  }
}
