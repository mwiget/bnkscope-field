// Render a title card to a PNG.
//
// ffmpeg is the obvious tool and cannot do it: Homebrew builds it without
// libfreetype, so the drawtext filter is simply absent. CoreText is already on
// every Mac that can build this app, needs no dependency, and gets the system
// font the app itself draws with — so the card and the app look related rather
// than merely adjacent.
import AppKit
import CoreText
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: card <out.png> <title> [subtitle]\n".utf8))
    exit(2)
}
let out = args[1], title = args[2]
let subtitle = args.count > 3 ? args[3] : ""

let w = 1920, h = 1080
// The app's own background, so a cut from card to screen recording does not
// change the colour of the room.
let bg = NSColor(srgbRed: 0x0B / 255.0, green: 0x0D / 255.0, blue: 0x12 / 255.0, alpha: 1)
let fg = NSColor(srgbRed: 0xE8 / 255.0, green: 0xEA / 255.0, blue: 0xED / 255.0, alpha: 1)
let dim = NSColor(srgbRed: 0x8A / 255.0, green: 0x93 / 255.0, blue: 0xA1 / 255.0, alpha: 1)

// Drawn into a bitmap of exactly 1920x1080 pixels, not an NSImage.
//
// NSImage.lockFocus() renders at the display's backing scale, so on a Retina
// Mac a 1920x1080 "image" comes out 3840x2160. Mixed with 1080p takes, the
// concat demuxer takes its dimensions from the first segment and the whole cut
// silently became 4K — the takes upscaled, the file four times the size.
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
    FileHandle.standardError.write(Data("cannot allocate bitmap\n".utf8))
    exit(1)
}
rep.size = NSSize(width: w, height: h)   // 1 point == 1 pixel
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
bg.setFill()
NSRect(x: 0, y: 0, width: w, height: h).fill()

func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centreY: CGFloat) {
    guard !text.isEmpty else { return }
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ]
    let s = NSAttributedString(string: text, attributes: attrs)
    let bounds = s.size()
    s.draw(at: NSPoint(x: (CGFloat(w) - bounds.width) / 2, y: centreY - bounds.height / 2))
}

if subtitle.isEmpty {
    draw(title, size: 96, weight: .semibold, color: fg, centreY: CGFloat(h) / 2)
} else {
    draw(title, size: 96, weight: .semibold, color: fg, centreY: CGFloat(h) / 2 + 44)
    draw(subtitle, size: 42, weight: .regular, color: dim, centreY: CGFloat(h) / 2 - 60)
}
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("could not encode\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: out))
