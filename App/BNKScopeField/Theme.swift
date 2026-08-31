import SwiftUI

/// The bnkscope web UI's dark tokens, carried over unchanged so the two read as
/// one product. The one addition is `live`: the logo's red, reserved here for
/// telemetry that is actually streaming. Blue stays what it is on the web —
/// selection and interactive chrome — so "selected" and "live" never look alike.
enum Theme {
    static let bg        = Color(hex: 0x111217)
    static let card      = Color(hex: 0x161A1F)
    static let border    = Color(hex: 0x303740)
    static let fg        = Color(hex: 0xCCCCDC)
    static let muted     = Color(hex: 0x7C7C9C)
    static let faint     = Color(hex: 0x5C6270)
    static let secondary = Color(hex: 0x1E2028)
    static let mutedBg   = Color(hex: 0x22252B)

    static let primary = Color(hex: 0x2563EB)
    static let ember   = Color(hex: 0xFF6A00)
    static let deep    = Color(hex: 0xE4002B)
    /// The logo's red. It belongs to the mark, and to nothing else.
    ///
    /// It was the "streaming" colour until someone pointed out that a
    /// troubleshooting tool showing its healthiest state in red is fighting
    /// every other red on the screen — including STALLED, which at #EF4444 was
    /// close enough to be mistaken for it at a glance. Broadcast convention says
    /// a live indicator is red; a monitoring convention says red is trouble, and
    /// in here the monitoring one wins.
    static let brand   = Color(hex: 0xFF3355)

    static let ok      = Color(hex: 0x10B981)
    static let warn    = Color(hex: 0xF59E0B)
    static let bad     = Color(hex: 0xEF4444)

    /// Series colours, assigned in this fixed order and never cycled.
    ///
    /// These are the web UI's chart hues stepped down for a dark surface — the
    /// originals sit above the lightness band that reads well on #161A1F. The
    /// three status hues are deliberately absent: amber, red and green mean
    /// something here, and a series that borrows one lies about its state.
    static let series: [Color] = [
        Color(hex: 0x3B82F6),   // blue
        Color(hex: 0x0D9488),   // teal
        Color(hex: 0x8B5CF6),   // violet
        Color(hex: 0xDB2777),   // pink
        Color(hex: 0x0891B2),   // cyan
    ]

    static func seriesColor(_ index: Int) -> Color {
        index < series.count ? series[index] : muted
    }

    static let mono = Font.system(.body, design: .monospaced)
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8)  & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// The bnkscope mark: a heptagonal scope with a waveform across it. Traced from
/// `frontend-v2/public/icons/bnkscope-small.svg` so the two stay the same shape.
struct BNKMark: View {
    var size: CGFloat = 28

    private static let bezel = Path { p in
        p.move(to: CGPoint(x: 32, y: 9.6))
        for pt in [CGPoint(x: 49.98, y: 18.26), CGPoint(x: 54.42, y: 37.72), CGPoint(x: 41.98, y: 53.32),
                   CGPoint(x: 22.02, y: 53.32), CGPoint(x: 9.58, y: 37.72), CGPoint(x: 14.02, y: 18.26)] {
            p.addLine(to: pt)
        }
        p.closeSubpath()
    }

    private static let beam = Path { p in
        let pts: [CGPoint] = [(15, 33), (18, 32.92), (19.5, 30.7), (21, 26.58), (22.5, 26.39),
                              (24.5, 28.48), (27, 32.82), (29, 35.74), (31, 37.01), (33, 36.44),
                              (35, 34.63), (37, 32.53), (39, 31.03), (41, 30.6), (43, 31.2),
                              (45, 32.39), (47, 33.59), (48, 34.03)].map { CGPoint(x: $0.0, y: $0.1) }
        p.move(to: pts[0])
        for pt in pts.dropFirst() { p.addLine(to: pt) }
    }

    var body: some View {
        Canvas { ctx, _ in
            ctx.fill(RoundedRectangle(cornerRadius: 14).path(in: CGRect(x: 2, y: 2, width: 60, height: 60)),
                     with: .color(Color(hex: 0x15181D)))
            ctx.fill(Self.bezel, with: .color(Color(hex: 0x0A0C10)))
            ctx.clip(to: Self.bezel)
            ctx.stroke(Self.beam,
                       with: .linearGradient(Gradient(colors: [Theme.brand, Theme.brand, Theme.ember]),
                                             startPoint: CGPoint(x: 12, y: 0), endPoint: CGPoint(x: 52, y: 0)),
                       style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 64, height: 64)
        .overlay {
            Self.bezel.stroke(Theme.deep, style: StrokeStyle(lineWidth: 2.6, lineJoin: .round))
                .frame(width: 64, height: 64)
        }
        .scaleEffect(size / 64)
        .frame(width: size, height: size)
    }
}
