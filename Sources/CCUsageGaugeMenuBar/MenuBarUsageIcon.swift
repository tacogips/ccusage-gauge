import AppCore
import AppKit
import CoreImage

@MainActor
enum MenuBarUsageIcon {
  private struct Artwork {
    let solid: NSImage
    let outline: NSImage
  }

  private static let context = CIContext(options: [.useSoftwareRenderer: true])
  private static let claude = artwork(MenuBarProviderIcons.claude)
  private static let codex = artwork(MenuBarProviderIcons.chatGPT)

  static func image(chart: PieChartID, fraction: Double?) -> NSImage {
    let artwork = chart.provider == .claude ? claude : codex
    let normalized = fraction.map { $0.isFinite ? min(max($0, 0), 1) : 0 }
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
      artwork.outline.draw(in: bounds)
      if let normalized {
        // AppKit's unflipped coordinates start at the bottom of the icon.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height * normalized)).addClip()
        artwork.solid.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
      } else {
        let slash = NSBezierPath()
        slash.move(to: NSPoint(x: bounds.minX + 2, y: bounds.minY + 2))
        slash.line(to: NSPoint(x: bounds.maxX - 2, y: bounds.maxY - 2))
        slash.lineWidth = 1
        NSColor.black.setStroke()
        slash.stroke()
      }
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = normalized.map { "\(RateLimitDisplayFormatting.title(for: chart)) \(Int(($0 * 100).rounded()))% used" }
      ?? "\(RateLimitDisplayFormatting.title(for: chart)) unavailable"
    return image
  }

  private static func artwork(_ source: NSImage) -> Artwork {
    guard let original = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      preconditionFailure("Invalid provider artwork")
    }
    let bitmap = NSBitmapImageRep(cgImage: original)
    var minX = bitmap.pixelsWide
    var minY = bitmap.pixelsHigh
    var maxX = 0
    var maxY = 0
    for y in 0..<bitmap.pixelsHigh {
      for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
      }
    }
    guard minX <= maxX, minY <= maxY,
          let cgImage = original.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else {
      preconditionFailure("Empty provider artwork")
    }
    let size = NSSize(width: 18, height: 18)
    let solid = NSImage(cgImage: cgImage, size: size)
    let input = CIImage(cgImage: cgImage)
    // Subtract an eroded mask to retain the actual mark's outer and inner edges.
    let eroded = input.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: max(1, CGFloat(cgImage.width) / 18 * 0.5)])
    guard let innerMask = context.createCGImage(eroded, from: input.extent) else {
      preconditionFailure("Could not outline provider artwork")
    }
    let interior = NSImage(cgImage: innerMask, size: size)
    let outline = NSImage(size: size, flipped: false) { bounds in
      solid.draw(in: bounds)
      interior.draw(in: bounds, from: .zero, operation: .destinationOut, fraction: 1)
      return true
    }
    return Artwork(solid: solid, outline: outline)
  }
}
