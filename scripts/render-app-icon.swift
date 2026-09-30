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

// Flat usage pie: the base mirrors --color-bg; the used wedge is solid white over a translucent white rail.
private enum IconColors {
  static let base = CGColor(red: 15 / 255, green: 17 / 255, blue: 21 / 255, alpha: 1)
  static let used = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
  static let rail = CGColor(red: 1, green: 1, blue: 1, alpha: 0.24)
  static let usedFraction: CGFloat = 0.68
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

  let radius = side * 0.34
  let explode = side * 0.03
  let startAngle: CGFloat = 90
  let endAngle = startAngle - IconColors.usedFraction * 360
  // Shift the pie back by half the explode offset so the composition stays optically centered.
  let usedBisector = radians((startAngle + endAngle) / 2)
  let center = CGPoint(
    x: side * 0.5 - cos(usedBisector) * explode * 0.5,
    y: side * 0.5 - sin(usedBisector) * explode * 0.5
  )

  // The used wedge is pulled out along its bisector, which leaves a clean gap without any outline stroke.
  func sector(from start: CGFloat, to end: CGFloat, offset: CGFloat) -> CGPath {
    let bisector = radians((start + end) / 2)
    let origin = CGPoint(x: center.x + cos(bisector) * offset, y: center.y + sin(bisector) * offset)
    let path = CGMutablePath()
    path.move(to: origin)
    path.addArc(center: origin, radius: radius, startAngle: radians(start), endAngle: radians(end), clockwise: true)
    path.closeSubpath()
    return path
  }

  context.addPath(sector(from: endAngle, to: startAngle - 360, offset: 0))
  context.setFillColor(IconColors.rail)
  context.fillPath()

  context.addPath(sector(from: startAngle, to: endAngle, offset: explode))
  context.setFillColor(IconColors.used)
  context.fillPath()

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
