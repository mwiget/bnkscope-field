import 'package:bnk_kit/bnk_kit.dart';

import 'cluster_store.dart';
import 'observable.dart';

enum Severity { healthy, warning, critical }

class Finding {
  final Severity severity;
  final String title;
  final String detail;

  /// Where to look next, when there is somewhere.
  final String? pod;
  final String? namespace;
  const Finding({required this.severity, required this.title, required this.detail, this.pod, this.namespace});
}

class ClusterReport {
  final String id;
  final String cluster;
  Severity severity = Severity.healthy;
  String headline = 'Nothing wrong';
  List<Finding> findings = const [];
  String nodes = '';
  ClusterReport({required this.id, required this.cluster});
}

/// Is anything wrong right now, and where.
///
/// The ranking deliberately does not lead on restart counts. On a cluster
/// that has been up for sixty days, argo-cd's repo-server has restarted 39
/// times and is perfectly healthy, while f5-dssm-sentinel-0 has restarted
/// 157 times and is genuinely broken; the difference is not the number, it
/// is that one of them is not ready now and has warnings arriving. So
/// readiness and recent warnings carry the weight, and restarts are context
/// shown beside them rather than a signal on their own.
class OverviewEngine extends Observable {
  /// A warning older than this is history, not a live fault. Kubernetes
  /// expires events after an hour by default, so anything still present and
  /// recent is genuinely current.
  static const recentWarning = Duration(minutes: 30);

  List<ClusterReport> _reports = const [];
  bool _scanning = false;
  DateTime? _scannedAt;

  List<ClusterReport> get reports => _reports;
  bool get scanning => _scanning;
  DateTime? get scannedAt => _scannedAt;

  Future<void> scan(List<ManagedCluster> clusters) async {
    _scanning = true;
    notify();
    final out = <ClusterReport>[];
    for (final cluster in clusters) {
      out.add(await report(cluster));
    }
    // Sorted by trouble, not by name.
    out.sort((a, b) => a.severity == b.severity
        ? a.cluster.compareTo(b.cluster)
        : b.severity.index.compareTo(a.severity.index));
    _reports = out;
    _scannedAt = DateTime.now();
    _scanning = false;
    notify();
  }

  Future<ClusterReport> report(ManagedCluster cluster) async {
    final report = ClusterReport(id: cluster.id, cluster: cluster.displayName);

    switch (cluster.reach) {
      case Unusable(:final why):
        report.severity = Severity.critical;
        report.headline = 'Cannot be used';
        report.findings = [Finding(severity: Severity.critical, title: 'Credentials this app cannot present', detail: why)];
        return report;
      case Unreachable(:final why):
        report.severity = Severity.critical;
        report.headline = 'Unreachable';
        report.findings = [Finding(severity: Severity.critical, title: 'No answer from the apiserver', detail: why)];
        return report;
      case Unprobed() || Reachable():
        break;
    }
    final client = cluster.clientOrNull;
    if (client == null) return report;

    final findings = <Finding>[];

    List<Node> nodes = const [];
    try {
      nodes = await client.nodes();
    } catch (_) {}
    report.nodes = '${nodes.where((n) => n.isReady).length}/${nodes.length} nodes ready';
    for (final node in nodes.where((n) => !n.isReady)) {
      findings.add(Finding(severity: Severity.critical, title: 'Node not ready', detail: node.metadata.name));
    }

    List<Pod> pods = const [];
    try {
      pods = await client.pods();
    } catch (_) {}
    for (final pod in pods) {
      final statuses = pod.status?.containerStatuses ?? const [];
      final phase = pod.status?.phase ?? '?';
      var restarts = 0;
      for (final s in statuses) {
        if ((s.restartCount ?? 0) > restarts) restarts = s.restartCount!;
      }
      if (phase != 'Running' && phase != 'Succeeded') {
        findings.add(Finding(
            severity: Severity.critical,
            title: pod.metadata.name,
            detail: '$phase in ${pod.metadata.namespace ?? '?'}',
            pod: pod.metadata.name,
            namespace: pod.metadata.namespace));
        continue;
      }
      final notReady = statuses.where((s) => s.ready != true).length;
      if (notReady > 0 && phase == 'Running') {
        final restartNote = restarts > 0 ? ' · $restarts restarts' : '';
        findings.add(Finding(
            severity: Severity.critical,
            title: pod.metadata.name,
            detail: 'running but $notReady of ${statuses.length} containers not ready$restartNote',
            pod: pod.metadata.name,
            namespace: pod.metadata.namespace));
      }
    }

    final cutoff = DateTime.now().subtract(recentWarning);
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    List<Event> warnings = const [];
    try {
      warnings = await client.warningEvents();
    } catch (_) {}
    warnings = warnings.where((e) => (e.at ?? epoch).isAfter(cutoff)).toList()
      ..sort((a, b) => (b.at ?? epoch).compareTo(a.at ?? epoch));
    for (final event in warnings.take(6)) {
      final name = event.involvedObject?.name ?? 'cluster';
      // A pod already reported as not-ready does not need a second row
      // saying the same thing in different words.
      if (findings.any((f) => f.pod == name)) continue;
      final count = event.count;
      findings.add(Finding(
          severity: Severity.warning,
          title: '${event.reason ?? 'Warning'}: $name',
          detail: tidy(event.message ?? '') + (count != null && count > 1 ? ' · ×$count' : ''),
          pod: event.involvedObject?.kind == 'Pod' ? name : null,
          namespace: event.involvedObject?.namespace));
    }

    // Telemetry that is installed but silent is worth saying on this
    // screen, because TMM Live will otherwise just look empty.
    if (cluster.roles.contains(ClusterRole.bnk)) {
      final missing = cluster.tmmPods.where((p) => !p.hasContainer(Exporter.containerName)).length;
      if (missing > 0) {
        findings.add(Finding(
            severity: Severity.warning,
            title: 'No exporter on $missing TMM pod${missing == 1 ? '' : 's'}',
            detail: 'TMM Live has nothing to scrape there, and is where you add it.'));
      }
    }

    findings.sort((a, b) => b.severity.index.compareTo(a.severity.index));
    report.findings = findings;
    report.severity = findings.isEmpty
        ? Severity.healthy
        : findings.map((f) => f.severity).reduce((a, b) => a.index >= b.index ? a : b);
    report.headline = headline(report.severity, findings.length);
    return report;
  }

  static String headline(Severity severity, int count) => switch (severity) {
        Severity.healthy => 'Nothing wrong',
        Severity.warning => '$count thing${count == 1 ? '' : 's'} worth a look',
        Severity.critical => '$count thing${count == 1 ? '' : 's'} wrong',
      };

  /// Kubernetes wraps repeated events in a preamble that says nothing.
  static String tidy(String message) {
    var text = message;
    const preamble = '(combined from similar events): ';
    final at = text.indexOf(preamble);
    if (at >= 0) text = text.substring(at + preamble.length);
    return text.length > 160 ? '${text.substring(0, 160)}…' : text;
  }
}
