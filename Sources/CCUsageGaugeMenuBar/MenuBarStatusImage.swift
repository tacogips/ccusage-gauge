import AppCore
import AppKit

struct MenuBarStatusEntry: Equatable {
  let chart: PieChartID
  let pie: MenuBarPieEntry?
  let ratio: String?
}

@MainActor
enum MenuBarStatusImage {
  static func image(entries: [MenuBarStatusEntry], accessibilityDescription: String) -> NSImage {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
      .foregroundColor: NSColor.black
    ]
    let widths = entries.map { entry -> CGFloat in
      let iconWidth: CGFloat = entry.chart == .budget && entry.pie == nil ? 0 : 18
      let ratioWidth = entry.ratio.map { ceil(($0 as NSString).size(withAttributes: attributes).width) + 3 } ?? 0
      return iconWidth + ratioWidth
    }
    let width = widths.reduce(0, +) + CGFloat(max(0, entries.count - 1)) * 7
    let image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { _ in
      var x: CGFloat = 0
      for (index, entry) in entries.enumerated() {
        let groupX = x
        if entry.chart != .budget {
          let fraction: Double?
          if case let .rateLimit(value) = entry.pie { fraction = value } else { fraction = nil }
          MenuBarUsageIcon.image(chart: entry.chart, fraction: fraction)
            .draw(in: NSRect(x: x, y: 0, width: 18, height: 18))
          x += 18
        } else if let pie = entry.pie {
          MenuBarPieStrip.image(entries: [pie], accessibilityDescription: "").draw(in: NSRect(x: x, y: 0, width: 18, height: 18))
          x += 18
        }
        if let ratio = entry.ratio {
          let size = (ratio as NSString).size(withAttributes: attributes)
          (ratio as NSString).draw(at: NSPoint(x: x + 3, y: (18 - size.height) / 2), withAttributes: attributes)
        }
        x = groupX + widths[index] + 7
      }
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = accessibilityDescription
    return image
  }
}
