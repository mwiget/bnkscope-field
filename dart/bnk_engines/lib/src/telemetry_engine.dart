import 'dart:async';

import 'package:bnk_kit/bnk_kit.dart';

import 'brief.dart';
import 'observable.dart';

/// One point on one plotted line.
///
/// [v] is null to record a break. A chart that joins the sample before a
/// sleep to the sample after it draws a clean ramp across minutes that were
/// never measured, which is worse than a hole, because it looks like data.
class Point {
  final DateTime t;
  final double? v;
  const Point(this.t, this.v);
}

/// A panel's worth of history: named lines, each a series of points.
class PanelData {
  final Map<String, List<Point>> lines = {};

  /// Line order is fixed by name, not by arrival, so a series that drops
  /// out for a scrape and comes back does not change colour.
  List<String> get names => lines.keys.toList()..sort();

  void append(Map<String, double> values, DateTime t, int limit) {
    for (final e in values.entries) {
      lines.putIfAbsent(e.key, () => []).add(Point(t, e.value));
    }
    _trim(limit);
  }

  /// Put a hole in every line. Called when the scrape stops, so the resumed
  /// series starts a new stroke rather than continuing the old one.
  void breakLines(DateTime t, int limit) {
    for (final line in lines.values) {
      if (line.isNotEmpty && line.last.v != null) line.add(Point(t, null));
    }
    _trim(limit);
  }

  void _trim(int limit) {
    for (final line in lines.values) {
      if (line.length > limit) line.removeRange(0, line.length - limit);
    }
  }

  /// The newest measured value, ignoring any trailing break.
  double? latest(String name) {
    final line = lines[name];
    if (line == null) return null;
    for (var i = line.length - 1; i >= 0; i--) {
      final v = line[i].v;
      if (v != null) return v;
    }
    return null;
  }
}

enum ValueFormat {
  percent,
  bitsPerSecond,
  count,
  perSecond;

  String call(double v) {
    switch (this) {
      case percent:
        return '${v.toStringAsFixed(1)}%';
      case count:
        return v.toStringAsFixed(0);
      case perSecond:
        return v >= 100 ? '${v.toStringAsFixed(0)}/s' : '${v.toStringAsFixed(1)}/s';
      case bitsPerSecond:
        const units = ['b/s', 'kb/s', 'Mb/s', 'Gb/s', 'Tb/s'];
        var x = v;
        var i = 0;
        while (x >= 1000 && i < units.length - 1) {
          x /= 1000;
          i++;
        }
        return '${i == 0 ? x.toStringAsFixed(0) : x.toStringAsFixed(2)} ${units[i]}';
    }
  }
}

enum PanelId {
  cpu('TMM CPU utilisation', '% · cycles-based, per pod', ValueFormat.percent),
  throughput('TMM client throughput', 'bit/s · software path only', ValueFormat.bitsPerSecond),
  connections('TMM current connections', 'client-side · instantaneous', ValueFormat.count),
  virtualServerConnRate('Virtual-server connection rate', 'new conns/s · per virtual server', ValueFormat.perSecond),
  poolMemberConnRate('Pool-member connection rate', 'new conns/s · the load-balance check', ValueFormat.perSecond),
  poolMemberConns('Pool-member connections', 'server-side · instantaneous, per member', ValueFormat.count),
  tenantConnRate('Per-tenant connection rate', 'new conns/s · from virtual-server names', ValueFormat.perSecond);

  final String title;
  final String unit;
  final ValueFormat format;
  const PanelId(this.title, this.unit, this.format);

  /// A fixed axis where the quantity has natural bounds. CPU running to
  /// 200% because the auto-scale padded a 97% reading makes the panel read
  /// as if there were headroom that does not exist.
  ({double min, double max})? get yDomain => this == cpu ? (min: 0, max: 100) : null;
}

sealed class PodStatus {
  const PodStatus();
}

class Answering extends PodStatus {
  final int samples;
  const Answering(this.samples);
}

class Failing extends PodStatus {
  final String why;
  const Failing(this.why);
}

sealed class TelemetryState {
  const TelemetryState();
}

class Idle extends TelemetryState {
  const Idle();
}

class Live extends TelemetryState {
  const Live();
}

class Paused extends TelemetryState {
  const Paused();
}

class Failed extends TelemetryState {
  final String why;
  const Failed(this.why);
}

class _Frame {
  final DateTime t;
  final Map<String, double> byName;
  final Map<String, double> bySeries;
  const _Frame(this.t, this.byName, this.bySeries);
}

class _Outcome {
  final String pod;
  final List<Sample>? samples;
  final Object? error;
  const _Outcome(this.pod, {this.samples, this.error});
}

/// A scrape loop's handle. Cancelling wakes a sleeping loop at once and
/// tells one mid-scrape not to write its result back.
class _Loop {
  bool cancelled = false;
  Completer<void>? _sleeping;

  Future<void> sleep(Duration d) {
    final c = Completer<void>();
    _sleeping = c;
    Timer(d, () {
      if (!c.isCompleted) c.complete();
    });
    return c.future;
  }

  void cancel() {
    cancelled = true;
    final c = _sleeping;
    if (c != null && !c.isCompleted) c.complete();
  }
}

/// Direct mode: the device scrapes the exporters itself and does the
/// arithmetic.
///
/// There is no Prometheus in this path, so the two things Prometheus would
/// do, hold the history and turn counters into rates, happen here. Only the
/// derived panel lines are kept: a scrape is ~2,400 series and retaining all
/// of them for half an hour would cost more memory than the whole app is
/// worth, while the panels need a few dozen.
class TelemetryEngine extends Observable {
  /// 2s matches the exporter's own push interval. Nothing is gained by
  /// asking faster than tmstat is sampled.
  final Duration liveInterval;

  /// 30 minutes at 2s.
  static const historyLimit = 900;

  /// How many scrapes in a row must fail before that is called a failure.
  ///
  /// A freshly injected exporter is not serving the moment the API call
  /// returns; the container still has to be created and started. Reporting
  /// the first refused connection as a fault put a full-screen error in
  /// front of the reader for the second or two before it worked.
  static const failuresBeforeGivingUp = 4;

  TelemetryEngine({this.liveInterval = const Duration(seconds: 2)});

  TelemetryState _state = const Idle();
  final Map<PanelId, PanelData> _panels = {};
  DateTime? _lastScrape;
  Duration _lastDuration = Duration.zero;
  double _achievedInterval = 0;
  int _bytesPerScrape = 0;
  int _reconnects = 0;
  int _failureStreak = 0;
  List<String> _targets = const [];
  final Map<String, PodStatus> _podStatus = {};

  KubeClient? _client;
  String _namespace = '';
  _Loop? _loop;
  final Map<String, PodScraper> _scrapers = {};
  final Map<String, _Frame> _previous = {};

  TelemetryState get state => _state;
  Map<PanelId, PanelData> get panels => _panels;
  DateTime? get lastScrape => _lastScrape;
  Duration get lastDuration => _lastDuration;

  /// The interval actually being achieved, in seconds, which is not
  /// [liveInterval] when a scrape takes longer than it.
  double get achievedInterval => _achievedInterval;
  int get bytesPerScrape => _bytesPerScrape;

  /// How often a tunnel had to be rebuilt. Zero is the expected value; a
  /// number that climbs means something keeps dropping them.
  int get reconnects => _reconnects;
  List<String> get targets => _targets;

  /// What each pod did on the last scrape: how many samples it returned, or
  /// why it did not answer. Whether an exporter is installed is a different
  /// question from whether it is currently talking.
  Map<String, PodStatus> get podStatus => _podStatus;

  /// Whether a scrape loop is running, distinct from [state], which reports
  /// what the loop found.
  bool get isRunning => _loop != null;

  // Lifecycle

  void start({required KubeClient client, required String namespace, required List<String> pods}) {
    stop();
    Log.telemetry.info('start: ${pods.length} pods in $namespace: ${pods.join(', ')}');
    _client = client;
    _namespace = namespace;
    _targets = pods;
    if (pods.isEmpty) {
      _state = const Failed('no f5-tmm pods on this cluster');
      notify();
      return;
    }
    _state = const Live();
    _failureStreak = 0;
    for (final pod in pods) {
      _scrapers[pod] = PodScraper(client: client, namespace: namespace, pod: pod);
    }
    final loop = _Loop();
    _loop = loop;
    _run(loop);
    notify();
  }

  /// Backgrounding stops the scrape entirely. In Direct mode there is
  /// nothing cluster-side to throttle; the device simply stops asking, and
  /// the history it already holds is still there when it comes back.
  void pause() {
    Log.telemetry.info('pause requested in state $_state');
    if (_state is! Live) return;
    _loop?.cancel();
    _loop = null;
    _state = const Paused();
    // Record the moment the measurements stop, so the charts show a gap
    // rather than a line drawn through it.
    final now = DateTime.now();
    for (final panel in _panels.values) {
      panel.breakLines(now, historyLimit);
    }
    // Let the tunnels go. Holding a kubelet stream into a live TMM pod open
    // for a screen nobody is looking at is exactly the cost this app is
    // supposed to be careful about.
    for (final scraper in _scrapers.values) {
      scraper.stop();
    }
    notify();
  }

  void resume() {
    Log.telemetry.info('resume requested in state $_state');
    if (_state is! Paused || _client == null) return;
    _state = const Live();
    // The gap is real and the next rate must not be computed across it: a
    // counter differenced over a ten-minute sleep would draw one enormous
    // spike. Dropping the previous frame makes the first scrape back a
    // baseline instead.
    _previous.clear();
    _lastScrape = null;
    final loop = _Loop();
    _loop = loop;
    _run(loop);
    notify();
  }

  /// Follow a changed set of pods without losing the history.
  ///
  /// The roster changes under a screen that is left open: a scenario
  /// restarts a tmm pod, and the pod that comes back carries no ephemeral
  /// container. Restarting the engine would pick that up, but [stop] clears
  /// every panel: half an hour of graphs thrown away because one pod of
  /// three changed.
  void retarget(List<String> pods) {
    Log.telemetry.info('retarget to ${pods.length} pods (running: ${_loop != null})');
    final client = _client;
    if (client == null || _loop == null) return;
    final wanted = pods.toSet();
    if (wanted.length == _targets.length && wanted.containsAll(_targets)) return;
    if (wanted.isEmpty) {
      stop();
      return;
    }
    for (final pod in _scrapers.keys.toList()) {
      if (wanted.contains(pod)) continue;
      _scrapers.remove(pod)!.stop();
      _previous.remove(pod);
      _podStatus.remove(pod);
    }
    for (final pod in wanted) {
      _scrapers.putIfAbsent(pod, () => PodScraper(client: client, namespace: _namespace, pod: pod));
    }
    _targets = pods;
    _failureStreak = 0;
    // A pod that went away took its lines with it. Break them rather than
    // joining the last reading to whatever comes next.
    final now = DateTime.now();
    for (final panel in _panels.values) {
      panel.breakLines(now, historyLimit);
    }
    if (_state is Failed) _state = const Live();
    notify();
  }

  void stop() {
    Log.telemetry.info('stop (was $_state, ${_scrapers.length} scrapers)');
    _loop?.cancel();
    _loop = null;
    _state = const Idle();
    _panels.clear();
    _previous.clear();
    _podStatus.clear();
    _lastScrape = null;
    _achievedInterval = 0;
    final leaving = _scrapers.values.toList();
    _scrapers.clear();
    for (final scraper in leaving) {
      scraper.stop();
    }
    notify();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  // The loop

  Future<void> _run(_Loop loop) async {
    while (!loop.cancelled) {
      final started = DateTime.now();
      await _scrapeOnce(loop);
      if (loop.cancelled) return;
      _lastDuration = DateTime.now().difference(started);
      notify();
      if (_lastDuration < liveInterval) await loop.sleep(liveInterval - _lastDuration);
    }
  }

  Future<void> _scrapeOnce(_Loop loop) async {
    if (_client == null) return;
    final active = Map<String, PodScraper>.of(_scrapers);
    if (active.isEmpty) {
      Log.telemetry.severe('scrape round with no scrapers (state $_state, streak $_failureStreak)');
    }

    // Pods are scraped concurrently: two tunnels read in sequence would put
    // the samples a round-trip apart and skew every per-pod comparison.
    final outcomes = await Future.wait([
      for (final e in active.entries)
        () async {
          try {
            return _Outcome(e.key, samples: await e.value.scrape());
          } catch (err) {
            return _Outcome(e.key, error: err);
          }
        }()
    ]);
    if (loop.cancelled) return;

    final frames = <String, List<Sample>>{};
    final failures = <String>[];
    for (final o in outcomes) {
      final samples = o.samples;
      if (samples != null) {
        frames[o.pod] = samples;
        _podStatus[o.pod] = Answering(samples.length);
      } else {
        failures.add('${o.pod}: ${o.error}');
        _podStatus[o.pod] = Failing(brief(o.error!));
      }
    }

    Log.telemetry.info('round: ${frames.length} answered, ${failures.length} failed of ${active.length}; state $_state');
    if (frames.isEmpty) {
      _failureStreak++;
      if (_failureStreak >= failuresBeforeGivingUp) {
        Log.telemetry.severe('giving up after $_failureStreak empty rounds: ${failures.firstOrNull ?? 'no scrapers'}');
        _state = Failed(failures.firstOrNull ?? 'every scrape failed');
      }
      notify();
      return;
    }
    _failureStreak = 0;
    if (_state is! Live) {
      Log.telemetry.info('back to live from $_state');
      _state = const Live();
    }
    final now = DateTime.now();
    final previousScrape = _lastScrape;
    if (previousScrape != null) {
      final gap = now.difference(previousScrape).inMicroseconds / 1e6;
      // Smoothed, so one slow scrape does not make the readout jump.
      _achievedInterval = _achievedInterval == 0 ? gap : _achievedInterval * 0.7 + gap * 0.3;
    }
    _lastScrape = now;
    _ingest(frames, now);
    var total = 0;
    for (final s in active.values) {
      total += s.reconnects;
    }
    _reconnects = total;
    notify();
  }

  // Deriving the panels

  void _ingest(Map<String, List<Sample>> frames, DateTime now) {
    final derived = <PanelId, Map<String, double>>{};
    Map<String, double> bucket(PanelId id) => derived.putIfAbsent(id, () => {});

    for (final e in frames.entries) {
      final pod = e.key;
      final samples = e.value;
      final short = shortPodName(pod);
      // /metrics carries no pod label, the exporter only adds those on the
      // remote_write path, so the scrape is tagged here with the pod it came
      // from. Without this every pod's series would collide.
      final frame = _Frame(now, total(samples, (s) => s.name), total(samples, (s) => s.seriesKey));
      final prev = _previous[pod];
      _previous[pod] = frame;

      // Gauges read straight off the frame.
      bucket(PanelId.connections)[short] = sum(samples, 'f5tmm_tmm_client_side_traffic_cur_conns');

      if (prev == null) continue;
      final dt = now.difference(prev.t).inMicroseconds / 1e6;
      if (dt <= 0.1) continue;

      /// A counter that went backwards means tmm restarted and reset it.
      /// There is no rate to report across that, so the series skips a
      /// point rather than drawing a negative one or a false spike.
      double? rate(String key, Map<String, double> Function(_Frame) side) {
        final a = side(prev)[key];
        final b = side(frame)[key];
        if (a == null || b == null || b < a) return null;
        return (b - a) / dt;
      }

      double? rateByName(String key) => rate(key, (f) => f.byName);
      double? rateBySeries(String key) => rate(key, (f) => f.bySeries);

      // CPU is derived from the cycle counters, not from cpu_usage: tmstat
      // marks constants and gauges alike as counters, and cpu_usage_1sec
      // reads ~2992 under load rather than a percentage.
      final idle = rateByName('f5tmm_tmm_tm_idle_cycles');
      final totalCycles = rateByName('f5tmm_tmm_tm_total_cycles');
      if (idle != null && totalCycles != null && totalCycles > 0) {
        bucket(PanelId.cpu)[short] = (1 - idle / totalCycles) * 100;
      }
      final bytesIn = rateByName('f5tmm_tmm_client_side_traffic_bytes_in');
      if (bytesIn != null) bucket(PanelId.throughput)['$short in'] = bytesIn * 8;
      final bytesOut = rateByName('f5tmm_tmm_client_side_traffic_bytes_out');
      if (bytesOut != null) bucket(PanelId.throughput)['$short out'] = bytesOut * 8;

      // Virtual servers and pool members, named as the cluster names them.
      // These two are the cluster-agnostic panels bnkscope's own dashboard
      // carries; the per-tenant panel below reads a naming convention only
      // the DPU clusters follow.
      for (final s in samples) {
        if (s.name != 'f5tmm_virtual_server_clientside_tot_conns') continue;
        final name = s.labels['name'];
        final r = rateBySeries(s.seriesKey);
        if (name == null || r == null) continue;
        final label = F5Names.shortObjectName(name);
        // A virtual server earns its line by having carried a connection,
        // the counter being off zero, and keeps it once it has. Admitting
        // only what is busy right now would be tighter, but then a screen
        // opened after a run reads exactly like a screen that is broken.
        if (!(r > 0 || s.value > 0 || _panels[PanelId.virtualServerConnRate]?.lines[label] != null)) continue;
        final b = bucket(PanelId.virtualServerConnRate);
        b[label] = (b[label] ?? 0) + r;
      }
      for (final s in samples) {
        if (s.name != 'f5tmm_pool_member_serverside_tot_conns') continue;
        final pool = s.labels['pool_name'];
        final addr = s.labels['addr'];
        final r = rateBySeries(s.seriesKey);
        if (pool == null || pool.startsWith('snat_automap') || addr == null || r == null) continue;
        final label = '${F5Names.shortObjectName(pool)} → $addr';
        if (!(r > 0 || s.value > 0 || _panels[PanelId.poolMemberConnRate]?.lines[label] != null)) continue;
        final b = bucket(PanelId.poolMemberConnRate);
        b[label] = (b[label] ?? 0) + r;
      }
      // Instantaneous connections as well as the rate: short-lived requests
      // can leave this at zero all through a run that the rate shows plainly.
      for (final s in samples) {
        if (s.name != 'f5tmm_pool_member_serverside_cur_conns') continue;
        // snat_automap is tmm's own source-NAT pool, not a load-balancing
        // target, and it has a member per tmm rather than per backend.
        final pool = s.labels['pool_name'];
        final addr = s.labels['addr'];
        if (pool == null || pool.startsWith('snat_automap') || addr == null) continue;
        final label = '${F5Names.shortObjectName(pool)} → $addr';
        if (!(s.value > 0 || _panels[PanelId.poolMemberConns]?.lines[label] != null)) continue;
        final b = bucket(PanelId.poolMemberConns);
        b[label] = (b[label] ?? 0) + s.value;
      }

      // Per-tenant connection rate, from the virtual-server names, the same
      // shape the Grafana dashboard gets with label_replace.
      for (final t in tenantKeys(samples, 'f5tmm_virtual_server_clientside_tot_conns').entries) {
        var r = 0.0;
        for (final key in t.value) {
          r += rateBySeries(key) ?? 0;
        }
        final b = bucket(PanelId.tenantConnRate);
        b[t.key] = (b[t.key] ?? 0) + r;
      }
    }

    for (final e in derived.entries) {
      _panels.putIfAbsent(e.key, PanelData.new).append(e.value, now, historyLimit);
    }
    var bytes = 0;
    for (final f in frames.values) {
      bytes += f.length;
    }
    _bytesPerScrape = bytes;
  }

  /// Total the samples under whichever key the caller needs: the metric
  /// name to aggregate a family, or the series key to keep its labels apart.
  static Map<String, double> total(List<Sample> samples, String Function(Sample) key) {
    final out = <String, double>{};
    for (final s in samples) {
      final k = key(s);
      out[k] = (out[k] ?? 0) + s.value;
    }
    return out;
  }

  static double sum(List<Sample> samples, String name) {
    var out = 0.0;
    for (final s in samples) {
      if (s.name == name) out += s.value;
    }
    return out;
  }

  /// Virtual servers are named `tenant-<tenant>-...`, which is where the
  /// per-tenant view comes from. A name that does not match is not a
  /// tenant's and is left out rather than bucketed under something invented.
  static Map<String, List<String>> tenantKeys(List<Sample> samples, String metric) {
    final out = <String, List<String>>{};
    for (final s in samples) {
      if (s.name != metric) continue;
      final name = s.labels['name'];
      if (name == null || !name.startsWith('tenant-')) continue;
      final parts = name.substring('tenant-'.length).split('-');
      if (parts.isEmpty || parts.first.isEmpty) continue;
      out.putIfAbsent(parts.first, () => []).add(s.seriesKey);
    }
    return out;
  }
}
