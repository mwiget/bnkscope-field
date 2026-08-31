import SwiftUI
import BNKKit

struct TMMLiveView: View {
    @Binding var columns: NavigationSplitViewVisibility
    @State private var explainingMode = false
    @State private var zoomed: PanelID?
    @Namespace private var panelZoom
    @Environment(ClusterStore.self) private var store
    @Environment(TelemetryEngine.self) private var engine

    private let grid = [GridItem(.adaptive(minimum: 320), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.border)
            content
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: store.selected) { await follow() }
    }

    // MARK: - Chrome

    private var toolbar: some View {
        HStack(spacing: 12) {
            SidebarToggle(columns: $columns)
            Text("TMM Live")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.fg)
                .fixedSize()
            if let cluster = store.current {
                Text(cluster.displayName)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            // The mode pill is the first thing to go when the window is too
            // narrow for everything: it says the same thing on every screen,
            // while the live pill is the one carrying state.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    modeButton
                    statePill
                }
                statePill
            }
            .fixedSize()
        }
        .padding(.horizontal, 20).frame(height: 58)
    }

    /// Says where the numbers come from, and — unlike the label it replaces —
    /// actually does something when tapped. A pill that looks exactly like the
    /// interactive ones beside it and is inert is a small trap.
    private var modeButton: some View {
        Button { explainingMode = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.left.arrow.up.right")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                Text("Direct").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                Image(systemName: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(Theme.secondary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $explainingMode, arrowEdge: .top) { modeExplainer }
    }

    private var modeExplainer: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Direct").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.fg)
                Text("Nothing is installed on the cluster. The iPad opens a port-forward to each f5-tmm pod through the apiserver, scrapes the exporter itself, and works out the rates here.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            Divider().overlay(Theme.border)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Edge").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.fg)
                    Badge(text: "not built yet", color: Theme.muted)
                }
                Text("Would run a small collector in its own namespace, so history survives the iPad sleeping and logs can be buffered cluster-side. One namespace to delete when you are done with it.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            Divider().overlay(Theme.border)
            Text("History here lasts as long as the app stays open — 30 minutes at most.")
                .font(.system(size: 12)).foregroundStyle(Theme.faint)
        }
        .padding(18)
        .frame(width: 360)
        .background(Theme.card)
        .presentationCompactAdaptation(.popover)
    }

    private var statePill: some View {
        Group {
            switch engine.state {
            case .live:
                // The measured cadence, not the target. A pill that says 2s
                // while the loop is turning every five seconds is the kind of
                // small lie that makes you distrust the chart next to it.
                Pill(text: "LIVE", detail: engine.achievedInterval > 0
                     ? String(format: "%.1fs", engine.achievedInterval) : "…", tone: .live)
            case .paused:
                Pill(text: "PAUSED", systemImage: "moon.fill", tone: .neutral)
            case .idle:
                Pill(text: "IDLE", tone: .neutral)
            case .failed:
                Pill(text: "STALLED", systemImage: "exclamationmark.triangle.fill", tone: .bad)
            }
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        switch engine.state {
        case .failed(let why):
            Message(title: "The scrape stopped", detail: why, tone: Theme.bad) {
                Button("Try again") { Task { await follow() } }.buttonStyle(.borderedProminent)
            }
        case .idle where store.current == nil:
            Message(title: "No cluster selected",
                    detail: "Pick a reachable cluster in the sidebar, or import a kubeconfig.", tone: Theme.muted)
        case .idle where (store.current?.tmmPods.isEmpty ?? true):
            Message(title: "No f5-tmm pods here",
                    detail: "TMM Live needs a cluster running BNK. This one has nothing to scrape.")
        case .idle:
            ExporterPanel(style: .prompt)
        case _ where zoomed != nil:
            zoomedPanel
        default:
            ScrollView {
                VStack(spacing: 16) {
                    tiles
                    LazyVGrid(columns: grid, spacing: 14) {
                        ForEach(PanelID.allCases, id: \.self) { panel in
                            if let data = engine.panels[panel], !data.lines.isEmpty {
                                ChartPanel(panel: panel, data: data,
                                           onToggleZoom: { zoom(panel) })
                                    .matchedGeometryEffect(id: panel, in: panelZoom)
                            }
                        }
                    }
                    ExporterPanel(style: .card)
                }
                .padding(20)
            }
        }
    }

    /// Wraps rather than squeezing. Four tiles across is right on a full-width
    /// window and unreadable in a narrow one.
    /// One panel, filling the window.
    ///
    /// The plot is sized from the space actually available rather than a fixed
    /// height — the whole point of zooming in is to spend the window on the
    /// chart.
    @ViewBuilder
    private var zoomedPanel: some View {
        if let panel = zoomed, let data = engine.panels[panel] {
            GeometryReader { geometry in
                ChartPanel(panel: panel, data: data,
                           height: max(160, geometry.size.height - 150),
                           isZoomed: true,
                           onToggleZoom: { zoom(nil) })
                    .matchedGeometryEffect(id: panel, in: panelZoom)
                    .frame(height: geometry.size.height)
            }
            .padding(20)
            // A keyboard or trackpad user reaches for Escape before they reach
            // for the button.
            .onKeyPress(.escape) { zoom(nil); return .handled }
        }
    }

    private func zoom(_ panel: PanelID?) {
        withAnimation(.snappy(duration: 0.28)) { zoomed = panel }
    }

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 14)], spacing: 14) {
            Tile(label: "TMM PODS", value: "\(engine.targets.count)", unit: "", sub: "scraped in parallel")
            Tile(label: "CURRENT CONNS",
                 value: ValueFormat.count(latest(.connections)), unit: "", sub: "client-side")
            Tile(label: "THROUGHPUT IN",
                 value: ValueFormat.bitsPerSecond(latest(.throughput, matching: " in")),
                 unit: "", sub: "software path · 10 s mean")
            Tile(label: "SCRAPE",
                 value: String(format: "%.2f", engine.lastDuration), unit: "s",
                 sub: engine.reconnects == 0
                     ? "\(engine.bytesPerScrape) samples · tunnel held"
                     : "\(engine.bytesPerScrape) samples · \(engine.reconnects) reconnects")
        }
    }

    /// Sum across a panel's lines at the newest point.
    ///
    /// `matching` narrows it to one direction: adding inbound bits to outbound
    /// bits produces a number that is not any throughput anyone asked about.
    private func latest(_ panel: PanelID, matching suffix: String? = nil) -> Double {
        guard let data = engine.panels[panel] else { return 0 }
        return data.lines
            .filter { suffix == nil || $0.key.hasSuffix(suffix!) }
            .values
            .map { Self.smoothed($0) }
            .reduce(0, +)
    }

    /// The mean of the last few points rather than the last one.
    ///
    /// Throughput on an idle lab arrives in bursts, so the newest sample is
    /// often zero between them. A headline number that flickers between 0 and
    /// 3 kb/s twice a second is unreadable and looks broken; the chart beside it
    /// is where the spikes belong.
    private static func smoothed(_ points: [Point], over n: Int = 5) -> Double {
        let tail = points.compactMap(\.v).suffix(n)
        guard !tail.isEmpty else { return 0 }
        return tail.reduce(0, +) / Double(tail.count)
    }

    // MARK: - Wiring

    private func follow() async {
        engine.stop()
        guard let cluster = store.current, cluster.isUsable else { return }
        if case .unprobed = cluster.reach { await cluster.probe() }
        guard case .reachable = cluster.reach else { return }
        let pods = cluster.tmmPods.filter { $0.has(container: "tmm-stat-exporter") }
        // Nothing carrying the exporter is not a failure; it is the state the
        // install prompt exists for. Starting the engine here would report "no
        // f5-tmm pods" instead, which is both wrong and a dead end.
        guard !pods.isEmpty,
              let namespace = cluster.tmmPods.first?.metadata.namespace,
              let client = try? cluster.client() else { return }
        engine.start(client: client, namespace: namespace, pods: pods.map(\.metadata.name))
    }
}

// MARK: - Small pieces

struct Pill: View {
    enum Tone { case live, neutral, bad }
    var text: String
    var detail: String?
    var systemImage: String?
    var tone: Tone = .neutral

    init(text: String, detail: String? = nil, systemImage: String? = nil, tone: Tone = .neutral) {
        self.text = text; self.detail = detail; self.systemImage = systemImage; self.tone = tone
    }

    private var color: Color {
        switch tone {
        case .live: return Theme.ok
        case .bad:  return Theme.bad
        case .neutral: return Theme.muted
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            if tone == .live {
                StatusDot(color: Theme.ok, glow: true)
            } else if let systemImage {
                Image(systemName: systemImage).font(.system(size: 12)).foregroundStyle(color)
            }
            Text(text)
                .font(.system(size: 12, weight: tone == .live ? .bold : .semibold))
                .kerning(tone == .live ? 0.7 : 0)
                .foregroundStyle(tone == .neutral ? Theme.muted : color)
            if let detail {
                Text(detail).font(Theme.mono(11.5)).foregroundStyle(color.opacity(0.75))
            }
        }
        .padding(.horizontal, 12).frame(height: 32)
        .background(tone == .neutral ? Theme.secondary : color.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(tone == .neutral ? Theme.border : color.opacity(0.25)))
    }
}

struct Tile: View {
    let label: String, value: String, unit: String, sub: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .semibold)).kerning(0.55).foregroundStyle(Theme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(Theme.mono(26, weight: .semibold)).foregroundStyle(Theme.fg)
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                if !unit.isEmpty {
                    Text(unit).font(Theme.mono(12)).foregroundStyle(Theme.muted)
                }
            }
            Text(sub).font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }
}

struct Message<Actions: View>: View {
    let title: String, detail: String
    var tone: Color = Theme.muted
    @ViewBuilder var actions: () -> Actions

    init(title: String, detail: String, tone: Color = Theme.muted,
         @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.title = title; self.detail = detail; self.tone = tone; self.actions = actions
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.fg)
            Text(detail)
                .font(.system(size: 13)).foregroundStyle(tone)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
            actions()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}
