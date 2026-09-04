import 'dart:async';

import 'package:bnk_engines/bnk_engines.dart';
import 'package:bnk_kit/bnk_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chart.dart';
import '../engines.dart';
import '../observe.dart';
import '../theme.dart';
import '../widgets.dart';
import 'exporter_panel.dart';

/// Direct mode: the device scrapes the exporters itself and draws the
/// panels from what it derived.
class TMMLiveScreen extends StatefulWidget {
  const TMMLiveScreen({super.key});

  @override
  State<TMMLiveScreen> createState() => _TMMLiveScreenState();
}

class _TMMLiveScreenState extends State<TMMLiveScreen> {
  PanelId? _zoomed;
  String? _followed;
  List<String>? _exporterPods;
  Timer? _roster;
  int _followSerial = 0;

  @override
  void dispose() {
    _roster?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engines = Engines.of(context);
    final store = engines.store;
    final engine = engines.telemetry;
    final cluster = store.current;
    return Observe([store, engine, if (cluster != null) cluster], builder: (context) {
      // Keyed on the probe as well as the selection. Installing an exporter
      // changes what there is to scrape without changing which cluster is
      // selected, so a successful install must not leave the screen sitting
      // on its own install prompt.
      final pods = _currentExporterPods(store);
      if (_followed != (store.selected ?? '')) {
        _followed = store.selected ?? '';
        _exporterPods = pods;
        WidgetsBinding.instance.addPostFrameCallback((_) => _follow(store, engine));
      } else if (_exporterPods == null || !_sameList(_exporterPods!, pods)) {
        _exporterPods = pods;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (engine.isRunning) {
            engine.retarget(pods);
          } else {
            _follow(store, engine);
          }
        });
      }
      return Column(children: [
        _toolbar(context, store, engine),
        Expanded(child: _content(context, store, engine)),
      ]);
    });
  }

  // Chrome

  Widget _toolbar(BuildContext context, ClusterStore store, TelemetryEngine engine) {
    final cluster = store.current;
    return Toolbar(title: 'TMM Live', children: [
      if (cluster != null)
        Flexible(child: Text(cluster.displayName, style: Tokens.mono(11.5, color: Tokens.muted), maxLines: 1, overflow: TextOverflow.ellipsis)),
      const Spacer(),
      // The mode pill is the first thing to go when the window is too
      // narrow for everything: it says the same thing on every screen, while
      // the live pill is the one carrying state.
      LayoutBuilder(builder: (context, constraints) {
        final wide = MediaQuery.sizeOf(context).width >= 720;
        return Row(mainAxisSize: MainAxisSize.min, children: [
          if (wide) ...[_modeButton(context), const SizedBox(width: 12)],
          _statePill(engine),
        ]);
      }),
    ]);
  }

  /// Says where the numbers come from, and, unlike the label it replaces,
  /// actually does something when tapped. A pill that looks exactly like the
  /// interactive ones beside it and is inert is a small trap.
  Widget _modeButton(BuildContext context) => InkWell(
        onTap: () => _explainMode(context),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Tokens.secondary,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Tokens.border),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.swap_vert, size: 14, color: Tokens.muted),
            const SizedBox(width: 6),
            Text('Direct', style: Tokens.text(12, weight: FontWeight.w600, color: Tokens.muted)),
            const SizedBox(width: 6),
            const Icon(Icons.info_outline, size: 13, color: Tokens.faint),
          ]),
        ),
      );

  Future<void> _explainMode(BuildContext context) => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          content: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Direct', style: Tokens.text(16, weight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text('Nothing is installed on the cluster. This device opens a port-forward to each f5-tmm pod through the '
                  'apiserver, scrapes the exporter itself, and works out the rates here.',
                  style: Tokens.text(13, color: Tokens.muted)),
              const Padding(padding: EdgeInsets.symmetric(vertical: 14), child: Divider(height: 1, color: Tokens.border)),
              Row(children: [
                Text('Edge', style: Tokens.text(16, weight: FontWeight.w600)),
                const SizedBox(width: 8),
                const Pill('not built yet'),
              ]),
              const SizedBox(height: 6),
              Text('Would run a small collector in its own namespace, so history survives the device sleeping and logs '
                  'can be buffered cluster-side. One namespace to delete when you are done with it.',
                  style: Tokens.text(13, color: Tokens.muted)),
              const Padding(padding: EdgeInsets.symmetric(vertical: 14), child: Divider(height: 1, color: Tokens.border)),
              Text('History here lasts as long as the app stays open — 30 minutes at most.', style: Tokens.text(12, color: Tokens.faint)),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
        ),
      );

  Widget _statePill(TelemetryEngine engine) => switch (engine.state) {
        // The measured cadence, not the target. A pill that says 2s while
        // the loop is turning every five seconds is the kind of small lie
        // that makes you distrust the chart next to it.
        Live() => StatePill('LIVE', detail: engine.achievedInterval > 0 ? '${engine.achievedInterval.toStringAsFixed(1)}s' : '…', tone: PillTone.live),
        Paused() => const StatePill('PAUSED', icon: Icons.dark_mode, tone: PillTone.neutral),
        Idle() => const StatePill('IDLE', tone: PillTone.neutral),
        Failed() => const StatePill('STALLED', icon: Icons.warning_rounded, tone: PillTone.bad),
      };

  // Body

  Widget _content(BuildContext context, ClusterStore store, TelemetryEngine engine) {
    final cluster = store.current;
    switch (engine.state) {
      case Failed(:final why):
        // The targets card comes too, because the usual reason every scrape
        // stopped is that the exporter is gone: a restarted tmm pod comes
        // back without its ephemeral container. A bare error with a "Try
        // again" button offers the one action that cannot help.
        return ListView(padding: const EdgeInsets.all(20), children: [
          Message(
            title: 'The scrape stopped',
            detail: why,
            tone: Tokens.bad,
            action: FilledButton(onPressed: () => _follow(store, engine), child: const Text('Try again')),
          ),
          const SizedBox(height: 16),
          const ExporterPanel(style: ExporterStyle.card),
        ]);
      case Idle():
        if (cluster == null) {
          return const Message(title: 'No cluster selected', detail: 'Pick a reachable cluster in the sidebar, or import a kubeconfig.');
        }
        if (cluster.tmmPods.isEmpty) {
          return const Message(title: 'No f5-tmm pods here', detail: 'TMM Live needs a cluster running BNK. This one has nothing to scrape.');
        }
        return const ExporterPanel(style: ExporterStyle.prompt);
      case Live() when engine.lastScrape == null:
        return const Message(title: 'Waiting for the first samples', detail: 'The exporter has just been added. It takes a scrape or two to start serving.');
      case Live() || Paused():
        break;
    }
    final zoomed = _zoomed;
    final zoomedData = zoomed == null ? null : engine.panels[zoomed];
    if (zoomed != null && zoomedData != null) return _zoomedPanel(zoomed, zoomedData);
    return ListView(padding: const EdgeInsets.all(20), children: [
      _tiles(engine),
      const SizedBox(height: 16),
      LayoutBuilder(builder: (context, constraints) {
        final panels = [
          for (final id in PanelId.values)
            if (engine.panels[id] case final data? when data.lines.isNotEmpty)
              ChartPanel(key: ValueKey(id), panel: id, data: data, onToggleZoom: () => _zoom(id)),
        ];
        return _grid(constraints.maxWidth, minimum: 320, children: panels);
      }),
      const SizedBox(height: 16),
      const ExporterPanel(style: ExporterStyle.card),
    ]);
  }

  /// Wraps rather than squeezing. Four tiles across is right on a
  /// full-width window and unreadable in a narrow one.
  Widget _grid(double width, {required double minimum, required List<Widget> children}) {
    const gap = 14.0;
    final columns = ((width + gap) / (minimum + gap)).floor().clamp(1, children.isEmpty ? 1 : children.length);
    final cell = (width - gap * (columns - 1)) / columns;
    return Wrap(spacing: gap, runSpacing: gap, children: [
      for (final child in children) SizedBox(width: cell, child: child),
    ]);
  }

  /// One panel, filling the window. The plot is sized from the space
  /// actually available rather than a fixed height: the whole point of
  /// zooming in is to spend the window on the chart.
  Widget _zoomedPanel(PanelId panel, PanelData data) => Focus(
        autofocus: true,
        // A keyboard or trackpad user reaches for Escape before they reach
        // for the button.
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
            _zoom(null);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: LayoutBuilder(builder: (context, constraints) {
            return ChartPanel(
              key: ValueKey(panel),
              panel: panel,
              data: data,
              height: (constraints.maxHeight - 150).clamp(160.0, double.infinity),
              isZoomed: true,
              onToggleZoom: () => _zoom(null),
            );
          }),
        ),
      );

  void _zoom(PanelId? panel) => setState(() => _zoomed = panel);

  Widget _tiles(TelemetryEngine engine) => LayoutBuilder(builder: (context, constraints) {
        return _grid(constraints.maxWidth, minimum: 168, children: [
          Tile(label: 'TMM PODS', value: '${engine.targets.length}', sub: 'scraped in parallel'),
          Tile(label: 'CURRENT CONNS', value: ValueFormat.count(_latest(engine, PanelId.connections)), sub: 'client-side'),
          Tile(label: 'THROUGHPUT IN', value: ValueFormat.bitsPerSecond(_latest(engine, PanelId.throughput, suffix: ' in')), sub: 'software path · 10 s mean'),
          Tile(
            label: 'SCRAPE',
            value: (engine.lastDuration.inMilliseconds / 1000).toStringAsFixed(2),
            unit: 's',
            sub: engine.reconnects == 0
                ? '${engine.bytesPerScrape} samples · tunnel held'
                : '${engine.bytesPerScrape} samples · ${engine.reconnects} reconnects',
          ),
        ]);
      });

  /// Sum across a panel's lines at the newest point. [suffix] narrows it to
  /// one direction: adding inbound bits to outbound bits produces a number
  /// that is not any throughput anyone asked about.
  static double _latest(TelemetryEngine engine, PanelId panel, {String? suffix}) {
    final data = engine.panels[panel];
    if (data == null) return 0;
    var total = 0.0;
    for (final e in data.lines.entries) {
      if (suffix != null && !e.key.endsWith(suffix)) continue;
      total += _smoothed(e.value);
    }
    return total;
  }

  /// The mean of the last few points rather than the last one. Throughput
  /// on an idle lab arrives in bursts, so the newest sample is often zero
  /// between them; a headline that flickers between 0 and 3 kb/s twice a
  /// second is unreadable. The chart beside it is where the spikes belong.
  static double _smoothed(List<Point> points, {int over = 5}) {
    final tail = <double>[];
    for (var i = points.length - 1; i >= 0 && tail.length < over; i--) {
      final v = points[i].v;
      if (v != null) tail.add(v);
    }
    if (tail.isEmpty) return 0;
    return tail.reduce((a, b) => a + b) / tail.length;
  }

  // Wiring

  Future<void> _follow(ClusterStore store, TelemetryEngine engine) async {
    final serial = ++_followSerial;
    _roster?.cancel();
    engine.stop();
    final cluster = store.current;
    if (cluster == null || !cluster.isUsable) return;
    if (cluster.reach is Unprobed) await cluster.probe();
    if (serial != _followSerial || !mounted) return;
    if (cluster.reach is! Reachable) return;
    final pods = cluster.tmmPods.where((p) => p.hasContainer(Exporter.containerName)).toList();
    // Nothing carrying the exporter is not a failure; it is the state the
    // install prompt exists for. Starting the engine here would report "no
    // f5-tmm pods" instead, which is both wrong and a dead end.
    final namespace = cluster.tmmPods.firstOrNull?.metadata.namespace;
    final client = cluster.clientOrNull;
    if (pods.isNotEmpty && namespace != null && client != null) {
      engine.start(client: client, namespace: namespace, pods: [for (final p in pods) p.metadata.name]);
    }
    // Re-list the cluster's tmm pods while the screen is open. Nothing else
    // notices when the cluster changes underneath: a scenario restarts a tmm
    // pod, the pod that comes back has no ephemeral container, and the
    // screen would go on scraping a pod that is gone.
    _roster = Timer.periodic(const Duration(seconds: 20), (_) => cluster.probe());
  }

  static List<String> _currentExporterPods(ClusterStore store) => [
        for (final p in store.current?.tmmPods ?? const <Pod>[])
          if (p.hasContainer(Exporter.containerName)) p.metadata.name
      ]..sort();

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

enum PillTone { live, neutral, bad }

/// The toolbar's state pill: LIVE with its cadence, PAUSED, IDLE, STALLED.
class StatePill extends StatelessWidget {
  final String text;
  final String? detail;
  final IconData? icon;
  final PillTone tone;
  const StatePill(this.text, {super.key, this.detail, this.icon, this.tone = PillTone.neutral});

  @override
  Widget build(BuildContext context) {
    final color = switch (tone) {
      PillTone.live => Tokens.ok,
      PillTone.bad => Tokens.bad,
      PillTone.neutral => Tokens.muted,
    };
    final neutral = tone == PillTone.neutral;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: neutral ? Tokens.secondary : color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: neutral ? Tokens.border : color.withValues(alpha: 0.25)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (tone == PillTone.live)
          const StatusDot(color: Tokens.ok, glow: true)
        else if (icon != null)
          Icon(icon, size: 13, color: color),
        if (tone == PillTone.live || icon != null) const SizedBox(width: 7),
        Text(text,
            style: Tokens.text(12, weight: tone == PillTone.live ? FontWeight.w700 : FontWeight.w600, color: neutral ? Tokens.muted : color)
                .copyWith(letterSpacing: tone == PillTone.live ? 0.7 : 0)),
        if (detail != null) ...[
          const SizedBox(width: 7),
          Text(detail!, style: Tokens.mono(11.5, color: color.withValues(alpha: 0.75))),
        ],
      ]),
    );
  }
}
