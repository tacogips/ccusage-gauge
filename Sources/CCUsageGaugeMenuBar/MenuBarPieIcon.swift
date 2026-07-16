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
      NSColor.black.setStroke()
      let outline = NSBezierPath(ovalIn: circle)
      outline.lineWidth = 1.5
      outline.stroke()

      if let fraction {
        drawSlice(fraction: fraction, circle: circle)
      } else if hasBudget {
        drawUnknownSlice(circle: circle)
      } else {
        drawBudgetMarker(circle: circle)
      }
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = warning ? "Warning: ccusage unavailable" : "Budget usage pie chart"
    return image
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

  private static func drawSlice(fraction: Decimal, circle: NSRect) {
    let normalized = min(max(CGFloat(truncating: fraction as NSDecimalNumber), 0), 1)
    guard normalized > 0 else { return }
    let center = NSPoint(x: circle.midX, y: circle.midY)
    let slice = NSBezierPath()
    slice.move(to: center)
    slice.appendArc(
      withCenter: center,
      radius: circle.width / 2,
      startAngle: 90,
      endAngle: 90 - normalized * 360,
      clockwise: true
    )
    slice.close()
    NSColor.black.setFill()
    slice.fill()
  }

  private static func drawUnknownSlice(circle: NSRect) {
    let center = NSPoint(x: circle.midX, y: circle.midY)
    let slice = NSBezierPath()
    slice.move(to: center)
    slice.appendArc(withCenter: center, radius: circle.width / 2, startAngle: 90, endAngle: 0, clockwise: true)
    slice.close()
    NSColor.black.setFill()
    slice.fill()
  }

  private static func drawBudgetMarker(circle: NSRect) {
    let marker = NSBezierPath()
    marker.move(to: NSPoint(x: circle.midX, y: circle.minY + 2))
    marker.line(to: NSPoint(x: circle.midX, y: circle.maxY - 2))
    marker.lineWidth = 1.5
    NSColor.black.setStroke()
    marker.stroke()
  }
}
