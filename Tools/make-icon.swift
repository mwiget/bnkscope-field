import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Draws the bnkscope mark at icon size, from the same path data as
// frontend-v2/public/icons/bnkscope-small.svg so the app and the web UI carry
// the same shape rather than two drawings of the same idea.
//
// Usage: swift Tools/make-icon.swift <AppIcon.appiconset directory>

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func colour(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
    CGColor(srgbRed: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, alpha: alpha)
}

/// The mark, filling its canvas edge to edge.
func artwork(side: Double) -> CGImage {
    let scale = side / 64.0                     // the SVG's viewBox is 64 wide
    func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }

    guard let ctx = CGContext(data: nil, width: Int(side), height: Int(side),
                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create the bitmap context")
    }
    // SVG's y grows downward; Core Graphics' grows up.
    ctx.translateBy(x: 0, y: side)
    ctx.scaleBy(x: 1, y: -1)

    let bezel = CGGradient(colorsSpace: space,
                           colors: [colour(0x22272E), colour(0x0B0E12)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(bezel, start: .zero, end: CGPoint(x: 0, y: side), options: [])

    let heptagon = CGMutablePath()
    let corners = [(32.0, 9.6), (49.98, 18.26), (54.42, 37.72), (41.98, 53.32),
                   (22.02, 53.32), (9.58, 37.72), (14.02, 18.26)]
    heptagon.move(to: p(corners[0].0, corners[0].1))
    for corner in corners.dropFirst() { heptagon.addLine(to: p(corner.0, corner.1)) }
    heptagon.closeSubpath()

    ctx.saveGState()
    ctx.addPath(heptagon)
    ctx.setFillColor(colour(0x0A0C10))
    ctx.fillPath()
    ctx.restoreGState()

    // The waveform, clipped to the screen it is drawn on.
    ctx.saveGState()
    ctx.addPath(heptagon)
    ctx.clip()

    let beam = CGMutablePath()
    let trace = [(15.0, 33.0), (18, 32.92), (19.5, 30.7), (21, 26.58), (22.5, 26.39),
                 (24.5, 28.48), (27, 32.82), (29, 35.74), (31, 37.01), (33, 36.44),
                 (35, 34.63), (37, 32.53), (39, 31.03), (41, 30.6), (43, 31.2),
                 (45, 32.39), (47, 33.59), (48, 34.03)]
    beam.move(to: p(trace[0].0, trace[0].1))
    for point in trace.dropFirst() { beam.addLine(to: p(point.0, point.1)) }

    ctx.setLineWidth(4 * scale)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(beam)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let sweep = CGGradient(colorsSpace: space,
                           colors: [colour(0xFF3355), colour(0xFF3355), colour(0xFF6A00)] as CFArray,
                           locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(sweep, start: p(12, 0), end: p(52, 0), options: [])
    ctx.restoreGState()

    ctx.addPath(heptagon)
    ctx.setStrokeColor(colour(0xE4002B))
    ctx.setLineWidth(2.6 * scale)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    guard let image = ctx.makeImage() else { fatalError("could not render") }
    return image
}

/// The same mark on the macOS grid.
///
/// iOS masks its own rounded corners, so the artwork above fills the square and
/// lets the system clip it. macOS masks nothing: an icon is drawn exactly as
/// given, so a full-bleed square lands among rounded ones looking like a bug.
/// Apple's grid puts the shape in a 824pt rounded square centred on a 1024pt
/// canvas — a tenth of the width as clear margin on every side — and the rest
/// of the canvas stays transparent.
func macIcon(side: Double, from art: CGImage) -> CGImage {
    guard let ctx = CGContext(data: nil, width: Int(side), height: Int(side),
                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create the bitmap context")
    }
    ctx.interpolationQuality = .high
    let inset = side * 100.0 / 1024.0
    let box = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = side * 185.0 / 1024.0
    ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    ctx.draw(art, in: box)
    guard let image = ctx.makeImage() else { fatalError("could not render") }
    return image
}

func write(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("could not open \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let icnsPath = URL(fileURLWithPath: CommandLine.arguments[2])
let master = artwork(side: 1024)

write(master, to: directory.appending(path: "AppIcon.png"))

// iOS only. The macOS icon is built here into an .icns rather than left to the
// asset catalogue: given a classic appiconset, actool in Xcode 27 emits only
// four of the ten sizes — 16, 32, 128 and 256 — so the Dock and Finder scale a
// 256 up to 512 and 1024 and it shows. iconutil, handed exactly the same PNGs,
// writes all ten.
let contents = """
{
  "images" : [
    {
      "filename" : "AppIcon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

"""
try contents.write(to: directory.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
print("wrote AppIcon.png and Contents.json (iOS)")

let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "bnkscope-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 1 ? "" : "@\(scale)x"
        write(macIcon(side: Double(points * scale), from: master),
              to: iconset.appending(path: "icon_\(points)x\(points)\(suffix).png"))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", icnsPath.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(icnsPath.lastPathComponent) with 10 macOS sizes")
