#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private enum RenderError: Error, LocalizedError {
  case invalidRepositoryRoot
  case cannotCreateBitmap(size: Int)
  case cannotCreateImage(size: Int)
  case cannotCreatePNG(URL)
  case cannotWritePNG(URL)
  case iconutilFailed(status: Int32)

  var errorDescription: String? {
    switch self {
    case .invalidRepositoryRoot:
      "run from the repository root"
    case let .cannotCreateBitmap(size):
      "could not create a \(size)px bitmap context"
    case let .cannotCreateImage(size):
      "could not create a \(size)px image"
    case let .cannotCreatePNG(url):
      "could not create PNG destination at \(url.path)"
    case let .cannotWritePNG(url):
      "could not write PNG at \(url.path)"
    case let .iconutilFailed(status):
      "iconutil failed with status \(status)"
    }
  }
}

// The base and progress mirror --color-bg and --color-accent; bars mirror the first slot of MODEL_COLOR_FAMILIES.
private enum IconColors {
  static let base = CGColor(red: 15 / 255, green: 17 / 255, blue: 21 / 255, alpha: 1)
  static let rail = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
  static let progress = CGColor(red: 39 / 255, green: 123 / 255, blue: 90 / 255, alpha: 1)
  static let anthropic = CGColor(red: 215 / 255, green: 140 / 255, blue: 87 / 255, alpha: 1)
  static let openAI = CGColor(red: 85 / 255, green: 189 / 255, blue: 207 / 255, alpha: 1)
  static let other = CGColor(red: 205 / 255, green: 103 / 255, blue: 215 / 255, alpha: 1)
}

private func radians(_ degrees: CGFloat) -> CGFloat {
  degrees * .pi / 180
}

private func drawIcon(size: Int) throws -> CGImage {
  let side = CGFloat(size)
  guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
          data: nil,
          width: size,
          height: size,
          bitsPerComponent: 8,
          bytesPerRow: size * 4,
          space: colorSpace,
          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        )
  else {
    throw RenderError.cannotCreateBitmap(size: size)
  }

  context.setShouldAntialias(true)
  context.setFillColor(IconColors.base)
  context.fill(CGRect(x: 0, y: 0, width: side, height: side))

  let center = CGPoint(x: side * 0.5, y: side * 0.5)
  let radius = side * 0.32
  let lineWidth = side * 0.085

  func strokeArc(start: CGFloat, end: CGFloat, color: CGColor) {
    let path = CGMutablePath()
    path.addArc(
      center: center,
      radius: radius,
      startAngle: radians(start),
      endAngle: radians(end),
      clockwise: true
    )
    context.addPath(path)
    context.setStrokeColor(color)
    context.setLineWidth(lineWidth)
    context.setLineCap(.butt)
    context.strokePath()
  }

  strokeArc(start: 225, end: -45, color: IconColors.rail)
  strokeArc(start: 225, end: 225 - (0.62 * 270), color: IconColors.progress)

  let barWidth = side * 0.075
  let gap = side * 0.035
  let groupWidth = barWidth * 3 + gap * 2
  let firstX = (side - groupWidth) * 0.5
  let baseline = side * 0.30
  let bars: [(height: CGFloat, color: CGColor)] = [
    (0.14, IconColors.anthropic),
    (0.22, IconColors.openAI),
    (0.18, IconColors.other)
  ]

  for (index, bar) in bars.enumerated() {
    let rect = CGRect(
      x: firstX + CGFloat(index) * (barWidth + gap),
      y: baseline,
      width: barWidth,
      height: side * bar.height
    )
    context.setFillColor(bar.color)
    context.fill(rect)
  }

  guard let image = context.makeImage() else {
    throw RenderError.cannotCreateImage(size: size)
  }
  return image
}

private func writePNG(size: Int, to url: URL) throws {
  let image = try drawIcon(size: size)
  guard let destination = CGImageDestinationCreateWithURL(
    url as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
  ) else {
    throw RenderError.cannotCreatePNG(url)
  }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else {
    throw RenderError.cannotWritePNG(url)
  }
}

private func render(repositoryRoot: URL) throws {
  let resources = repositoryRoot.appendingPathComponent("Resources", isDirectory: true)
  try writePNG(size: 1024, to: resources.appendingPathComponent("AppIcon.png"))
  try writePNG(size: 128, to: resources.appendingPathComponent("DashboardIcon.png"))

  let temporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

  let iconset = temporaryDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
  try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
  let entries: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
  ]
  for entry in entries {
    try writePNG(size: entry.size, to: iconset.appendingPathComponent(entry.name))
  }

  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
  process.arguments = [
    "-c", "icns", iconset.path,
    "-o", resources.appendingPathComponent("AppIcon.icns").path
  ]
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    throw RenderError.iconutilFailed(status: process.terminationStatus)
  }
}

let fileManager = FileManager.default
let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
guard fileManager.fileExists(atPath: currentDirectory.appendingPathComponent("Package.swift").path),
      fileManager.fileExists(atPath: currentDirectory.appendingPathComponent("Resources").path)
else {
  FileHandle.standardError.write(Data("run from the repository root\n".utf8))
  exit(1)
}

do {
  try render(repositoryRoot: currentDirectory)
} catch {
  FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
  exit(1)
}
