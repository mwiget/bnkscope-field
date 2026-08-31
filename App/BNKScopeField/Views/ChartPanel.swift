import Charts
import SwiftUI

/// One dashboard panel.
///
/// Deliberately not a Grafana panel in a web view: on a tablet the chart is the
/// thing you touch, and a native chart gets the scrub gesture, the momentum and
/// the Metal compositing for free. The trade is that the panels are code rather
/// than dashboard JSON, so adding one is an edit here.
struct ChartPanel: View {
    let panel: PanelID
    let data: PanelData
    var height: CGFloat = 182
    /// Whether this panel is currently filling the window.
    var isZoomed = false
    /// Nil when zooming is not offered — a zoomed panel with no way out would
    /// be a trap.
    var onToggleZoom: (() -> Void)?

    @State private var scrubbed: Date?

    private var names: [String] { data.names }

    /// Colour follows the series' position in the sorted name list, so a line
    /// that stops reporting for a scrape keeps its colour when it returns.
    private func color(_ name: String) -> Color {
        Theme.seriesColor(names.firstIndex(of: name) ?? 0)
    }

    /// The value each line held at the scrubbed instant, or its latest.
    private func readout(_ name: String) -> Double? {
        guard let scrubbed, let points = data.lines[name] else { return data.latest(name) }
        return points
            .filter { $0.v != nil }
            .min(by: { abs($0.t.timeIntervalSince(scrubbed)) < abs($1.t.timeIntervalSince(scrubbed)) })?.v
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(panel.title)
                        .font(.system(size: isZoomed ? 16 : 13.5, weight: .semibold))
                        .foregroundStyle(Theme.fg)
                    Text(panel.unit)
                        .font(Theme.mono(isZoomed ? 11.5 : 10.5))
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
                if let onToggleZoom {
                    // The double-tap does the same thing, but a gesture nobody
                    // can see is a feature nobody finds.
                    Button(action: onToggleZoom) {
                        Image(systemName: isZoomed
                              ? "arrow.down.right.and.arrow.up.left"
                              : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.muted)
                            .frame(width: 26, height: 26)
                            .background(Theme.secondary, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isZoomed ? "Collapse \(panel.title)" : "Expand \(panel.title)")
                }
            }

            legend

            chart
                .frame(height: height)

        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
        .contentShape(Rectangle())
        // Double-tap on touch, double-click with a trackpad or mouse — the
        // gesture people already use to blow something up and put it back.
        .onTapGesture(count: 2) { onToggleZoom?() }
    }

    /// Always present for two or more lines, so identity never rests on colour
    /// alone. It doubles as the readout while scrubbing.
    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 12, alignment: .leading)],
                  alignment: .leading, spacing: 4) {
            ForEach(names.prefix(6), id: \.self) { name in
                LegendChip(name: name, color: color(name), value: readout(name).map { panel.format($0) })
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(names, id: \.self) { name in
                SeriesMarks(name: name, points: data.lines[name] ?? [], color: color(name))
            }
            if let scrubbed {
                RuleMark(x: .value("t", scrubbed))
                    .foregroundStyle(Theme.fg.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartLegend(.hidden)
        // Monotone interpolation overshoots, and Charts does not clip to the
        // plot area: a series sitting near the top of a fixed domain — TMM idles
        // at ~97% of a 0–100 axis — paints its area fill outside the panel and
        // over whatever is above it. Clipping the plot rather than the whole
        // chart keeps the axis labels, which sit outside it.
        .chartPlotStyle { $0.clipped() }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Theme.border.opacity(0.55))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(panel.format(v))
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.faint)
                    }
                }
            }
        }
        .chartXAxis {
            // Three marks, not four: the fourth lands on the plot's right edge
            // and its label is clipped to "12…".
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Theme.border.opacity(0.55))
                AxisValueLabel {
                    if let t = value.as(Date.self) {
                        // Minutes and seconds only. The window is half an hour at
                        // most, so the hour is the same on every label and only
                        // costs the width that makes them collide.
                        Text(t, format: .dateTime.minute().second())
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.faint)
                    }
                }
            }
        }
        .modifier(YScale(domain: panel.yDomain))
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                guard let plot = proxy.plotFrame else { return }
                                let x = g.location.x - geo[plot].origin.x
                                scrubbed = proxy.value(atX: x, as: Date.self)
                            }
                            .onEnded { _ in scrubbed = nil }
                    )
            }
        }
    }
}


/// One entry in a panel legend. Pulled out of `ChartPanel` because inlining it
/// pushed the body past what the type checker will infer in reasonable time.
private struct LegendChip: View {
    let name: String
    let color: Color
    let value: String?

    var body: some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 9, height: 2.5)
            Text(name)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
            if let value {
                Text(value)
                    .font(Theme.mono(10.5, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A fixed y-domain where the quantity has real bounds, and an automatic one
/// otherwise. Written as a modifier because the two branches are different
/// opaque types and cannot be an inline ternary.
private struct YScale: ViewModifier {
    let domain: ClosedRange<Double>?

    func body(content: Content) -> some View {
        if let domain {
            content.chartYScale(domain: domain)
        } else {
            content.chartYScale(domain: .automatic(includesZero: true))
        }
    }
}


/// One line and its fill.
///
/// A separate `ChartContent` rather than an inline `ForEach`: with the optional
/// y-value the inference cost of building this inside the panel body exceeds
/// what the type checker will spend.
private struct SeriesMarks: ChartContent {
    let name: String
    let points: [Point]
    let color: Color

    /// Runs of consecutive measured points. A break splits the line into two
    /// runs, and because each run is plotted as its own `series` Charts will not
    /// join them — which is the whole point: the gap has to stay a gap.
    private var segments: [[(t: Date, v: Double)]] {
        var out: [[(t: Date, v: Double)]] = []
        var run: [(t: Date, v: Double)] = []
        for point in points {
            if let v = point.v {
                run.append((point.t, v))
            } else if !run.isEmpty {
                out.append(run); run = []
            }
        }
        if !run.isEmpty { out.append(run) }
        return out
    }

    var body: some ChartContent {
        ForEach(Array(segments.enumerated()), id: \.offset) { index, run in
            ForEach(run, id: \.t) { point in
                AreaMark(x: .value("t", point.t), y: .value("v", point.v),
                         series: .value("s", "\(name)#\(index)"))
                .foregroundStyle(color.opacity(0.13))
                .interpolationMethod(.monotone)
            }
            ForEach(run, id: \.t) { point in
                LineMark(x: .value("t", point.t), y: .value("v", point.v),
                         series: .value("s", "\(name)#\(index)"))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                .interpolationMethod(.monotone)
            }
        }
    }
}
