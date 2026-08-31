import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Draws the bnkscope mark at icon size, from the same path data as
// frontend-v2/public/icons/bnkscope-small.svg so the app and the web UI carry
// the same shape rather than two drawings of the same idea.

let side = 1024.0
let scale = side / 64.0                     // the SVG's viewBox is 64 wide
func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: Int(side), height: Int(side),
                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("could not create the bitmap context")
}
// SVG's y grows downward; Core Graphics' grows up.
ctx.translateBy(x: 0, y: side)
ctx.scaleBy(x: 1, y: -1)

func colour(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
    CGColor(srgbRed: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, alpha: alpha)
}

// The bezel gradient from the full-size logo. iOS masks its own rounded corners,
// so this fills the square edge to edge rather than drawing corners that would
// be clipped into a double rounding.
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
let out = URL(fileURLWithPath: CommandLine.arguments[1])
guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("could not open \(out.path)")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write the png") }
print("wrote \(out.path)")
