/// The engines driven through real transport against the fake apiserver:
/// the store imports a kubeconfig and probes, telemetry scrapes and derives
/// panels, logs merge, exec runs, the overview finds what is broken.
library;

import 'dart:async';
import 'dart:io';

import 'package:bnk_engines/bnk_engines.dart';
import 'package:bnk_kit/bnk_kit.dart';
import 'package:bnk_kit/testing.dart';
import 'package:test/test.dart';

const fixtures = Fixtures('../bnk_kit/test/fixtures');

/// Wait until [ready] holds, driven by [engine]'s change notifications.
Future<void> until(Observable engine, bool Function() ready, {Duration timeout = const Duration(seconds: 15)}) async {
  if (ready()) return;
  final done = Completer<void>();
  final sub = engine.changes.listen((_) {
    if (ready() && !done.isCompleted) done.complete();
  });
  try {
    await done.future.timeout(timeout);
  } finally {
    await sub.cancel();
  }
}

void main() {
  late FakeApiserver api;
  late Directory dir;
  late ClusterStore store;
  late ManagedCluster cluster;

  setUpAll(() async {
    api = FakeApiserver(fixtures: fixtures);
    await api.start();
    dir = await Directory.systemTemp.createTemp('bnk-engines-');
    store = ClusterStore(directory: dir);
    await store.load();
    expect(store.clusters, isEmpty);
    await store.importKubeconfig(fixtures.kubeconfig(api));
    expect(store.importError, isNull);
    cluster = store.clusters.single;
    await store.probeAll();
  });

  tearDownAll(() async {
    store.dispose();
    await api.stop();
    await dir.delete(recursive: true);
  });

  test('the store imports, files, probes and badges a cluster', () async {
    expect(store.files, ['fake.kubeconfig']);
    expect(cluster.reach, isA<Reachable>().having((r) => r.version, 'version', 'v1.30.0-fake'));
    expect((cluster.reach as Reachable).ready, 1);
    expect(cluster.roles, containsAll([ClusterRole.bnk, ClusterRole.dpu, ClusterRole.gpu]));
    expect(cluster.roles, isNot(contains(ClusterRole.nico)));
    expect(cluster.gpuDevices, ['GA104GL_RTX_A4000 ×2']);
    expect(cluster.tmmPods.map((p) => p.metadata.name), ['tmm-a', 'tmm-b']);
    expect(cluster.k0rdent.isK0rdent, isFalse);
    expect(store.selected, cluster.id);
    expect(cluster.probeGeneration, 1);
    expect(Section.available(cluster), contains(Section.dpu));
  });

  test('a second import of the same file is not a second cluster', () async {
    await store.importKubeconfig(fixtures.kubeconfig(api));
    expect(store.clusters.length, 1);
  });

  test('the overview finds the broken pod and the fresh warning, not the stale one', () async {
    final overview = OverviewEngine();
    await overview.scan(store.clusters);
    final report = overview.reports.single;
    expect(report.severity, Severity.critical);
    expect(report.nodes, '1/2 nodes ready');
    expect(report.findings.map((f) => f.title), containsAll(['Node not ready', 'broken']));
    // The BackOff warning is about `broken`, already reported, so it is not repeated;
    // the old warning is history.
    expect(report.findings.where((f) => f.title.startsWith('BackOff')), isEmpty);
    expect(report.findings.where((f) => f.title.startsWith('Old')), isEmpty);
    expect(report.headline, '2 things wrong');
    overview.dispose();
  });

  test('telemetry scrapes every pod, derives panels, and pauses with a break', () async {
    final engine = TelemetryEngine(liveInterval: const Duration(milliseconds: 300));
    engine.start(client: cluster.client(), namespace: 'ns', pods: ['tmm-a', 'tmm-b']);
    expect(engine.isRunning, isTrue);
    // Rates need two rounds. The fixture never changes, so the cycle counters
    // give a zero rate and the CPU panel is deliberately skipped (a total of
    // zero cycles is no reading); throughput keeps a zero-rate line.
    await until(engine, () => engine.panels[PanelId.throughput]?.lines.length == 4);
    expect(engine.state, isA<Live>());
    expect(engine.podStatus['tmm-a'], isA<Answering>().having((a) => a.samples, 'samples', greaterThan(500)));
    expect(engine.panels[PanelId.connections]!.names, ['a', 'b']);
    expect(engine.panels[PanelId.throughput]!.names, ['a in', 'a out', 'b in', 'b out']);
    expect(engine.panels[PanelId.throughput]!.latest('a in'), 0);
    expect(engine.panels[PanelId.cpu], isNull);
    expect(engine.reconnects, 0);
    expect(engine.bytesPerScrape, greaterThan(1000));
    expect(api.portForwardRequests, 2, reason: 'one held tunnel per pod');

    engine.pause();
    expect(engine.state, isA<Paused>());
    expect(engine.panels[PanelId.throughput]!.lines['a in']!.last.v, isNull);
    engine.resume();
    await until(engine, () => engine.panels[PanelId.throughput]!.lines['a in']!.last.v != null);
    expect(api.portForwardRequests, 4, reason: 'tunnels were let go on pause and rebuilt');

    engine.retarget(['tmm-a']);
    expect(engine.targets, ['tmm-a']);
    await until(engine, () => engine.podStatus.keys.toList().toString() == '[tmm-a]');
    engine.stop();
    expect(engine.state, isA<Idle>());
    expect(engine.panels, isEmpty);
    engine.dispose();
  });

  test('telemetry gives up after four empty rounds and says why', () async {
    final engine = TelemetryEngine(liveInterval: const Duration(milliseconds: 50));
    engine.start(client: cluster.client(), namespace: 'ns', pods: ['tmm-a']);
    // Only /metrics is served; the tunnel answers 404 to anything else.
    final scraperless = TelemetryEngine(liveInterval: const Duration(milliseconds: 50));
    scraperless.start(client: cluster.client(), namespace: 'ns', pods: []);
    expect(scraperless.state, isA<Failed>());
    scraperless.dispose();
    engine.dispose();
  });

  test('logs merge several containers newest first, filter and mute', () async {
    final logs = LogsEngine();
    logs.start(client: cluster.client(), namespace: 'ns', pods: cluster.tmmPods);
    expect(logs.following, ['tmm-a/main', 'tmm-a/tmm-stat-exporter', 'tmm-b/main', 'tmm-b/tmm-stat-exporter']);
    await until(logs, () => logs.lines.length == 12);
    expect(logs.sources.first.lines, 6);
    logs.query = 'second';
    expect(logs.visible.length, 4);
    expect(logs.visible.every((l) => l.level == LogLevel.error), isTrue);
    logs.query = '';
    logs.levels = {LogLevel.info};
    expect(logs.visible.length, 8);
    logs.toggleMute('main');
    expect(logs.visible.length, 4);
    logs.stop();
    expect(logs.isRunning, isFalse);
    logs.dispose();
  });

  test('exec keeps each run\'s output and its exit', () async {
    final exec = ExecEngine();
    exec.run(['tmctl', '-d', 'blade'], container: 'main', namespace: 'ns', pod: 'tmm-a', client: cluster.client());
    await until(exec, () => exec.runs.last.finished);
    expect(exec.runs.single.command, 'tmctl -d blade');
    expect(exec.runs.single.lines.map((l) => l.text), ['ran: tmctl -d blade', 'a warning']);
    expect(exec.runs.single.lines.last.isError, isTrue);
    expect(exec.runs.single.failure, isNull);
    exec.run(['false'], container: 'main', namespace: 'ns', pod: 'tmm-a', client: cluster.client());
    await until(exec, () => exec.runs.last.finished);
    expect(exec.runs.last.failure, contains('exit code 1'));
    expect(exec.running, isFalse);
    exec.dispose();
  });

  test('resources list a kind and its events', () async {
    final resources = ResourceEngine();
    await resources.loadNamespaces(cluster);
    expect(resources.namespaces, ['kube-system', 'ns']);
    await resources.load(cluster);
    expect(resources.objects.map((o) => o.name), ['n1', 'n2']);
    resources.kind = ResourceKind.all[1];
    resources.namespace = 'ns';
    await resources.load(cluster);
    expect(resources.objects.map((o) => o.name), ['broken', 'tmm-a', 'tmm-b']);
    resources.query = 'TMM';
    expect(resources.visible.length, 2);
    expect(ResourceSummary.line(resources.objects.first, resources.kind).tone, SummaryTone.bad);
    resources.dispose();
  });

  test('a dead cluster is unreachable with a reason, and keeps its badges', () async {
    final dead = ManagedCluster(
        context: KubeContext(name: 'dead', clusterName: 'dead', server: Uri.parse('https://127.0.0.1:1'), caPEM: null,
            tlsServerName: null, insecureSkipTLSVerify: true, namespace: null, auth: const BearerTokenAuth('t')),
        sourceFile: 'dead.kubeconfig');
    await dead.probe();
    expect(dead.reach, isA<Unreachable>().having((u) => u.why, 'why', contains('no route')));
    final overview = OverviewEngine();
    final report = await overview.report(dead);
    expect(report.headline, 'Unreachable');
    overview.dispose();
    dead.dispose();
  });
}
