import AppKit
import Foundation

enum MenuBarPieIcon {
  private static let size = NSSize(width: 18, height: 18)

  static func image(fraction: Decimal?, hasBudget: Bool, warning: Bool = false) -> NSImage {
    let image = NSImage(size: size, flipped: false) { bounds in
      if warning {
        drawWarning(in: bounds)
        return true
      }
      let circle = bounds.insetBy(dx: 2, dy: 2)
      drawRail(circle: circle)

      if let fraction {
        drawUsedArc(fraction: fraction, circle: circle)
      } else if hasBudget {
        drawUnknownArc(circle: circle)
      } else {
        drawBudgetMarker(circle: circle)
      }
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = warning ? "Warning: ccusage unavailable" : "Budget usage gauge"
    return image
  }

  private static func drawRail(circle: NSRect) {
    let rail = NSBezierPath(ovalIn: circle)
    rail.lineWidth = 2.5
    rail.lineCapStyle = .butt
    NSColor.black.withAlphaComponent(0.35).setStroke()
    rail.stroke()
  }

  private static func drawWarning(in bounds: NSRect) {
    let triangle = NSBezierPath()
    triangle.move(to: NSPoint(x: bounds.midX, y: bounds.maxY - 1.5))
    triangle.line(to: NSPoint(x: bounds.maxX - 1, y: bounds.minY + 1.5))
    triangle.line(to: NSPoint(x: bounds.minX + 1, y: bounds.minY + 1.5))
    triangle.close()
    triangle.lineWidth = 1.5
    NSColor.black.setStroke()
    triangle.stroke()

    let mark = NSBezierPath()
    mark.move(to: NSPoint(x: bounds.midX, y: bounds.minY + 5))
    mark.line(to: NSPoint(x: bounds.midX, y: bounds.minY + 10.5))
    mark.lineWidth = 1.6
    mark.lineCapStyle = .round
    mark.stroke()
    NSColor.black.setFill()
    NSBezierPath(ovalIn: NSRect(x: bounds.midX - 0.9, y: bounds.minY + 2.5, width: 1.8, height: 1.8)).fill()
  }

  private static func drawUsedArc(fraction: Decimal, circle: NSRect) {
    let normalized = min(max(CGFloat(truncating: fraction as NSDecimalNumber), 0), 1)
    guard normalized > 0 else { return }
    let center = NSPoint(x: circle.midX, y: circle.midY)
    let arc = NSBezierPath()
    arc.appendArc(
      withCenter: center,
      radius: circle.width / 2,
      startAngle: 90,
      endAngle: 90 - normalized * 360,
      clockwise: true
    )
    arc.lineWidth = 2.5
    arc.lineCapStyle = .butt
    NSColor.black.setStroke()
    arc.stroke()
  }

  private static func drawUnknownArc(circle: NSRect) {
    let center = NSPoint(x: circle.midX, y: circle.midY)
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: circle.width / 2, startAngle: 90, endAngle: 0, clockwise: true)
    arc.lineWidth = 2.5
    arc.lineCapStyle = .butt
    NSColor.black.setStroke()
    arc.stroke()
  }

  private static func drawBudgetMarker(circle: NSRect) {
    let marker = NSBezierPath()
    marker.move(to: NSPoint(x: circle.midX, y: circle.minY + 2))
    marker.line(to: NSPoint(x: circle.midX, y: circle.maxY - 2))
    marker.lineWidth = 1.5
    marker.lineCapStyle = .butt
    NSColor.black.setStroke()
    marker.stroke()
  }
}
