import 'package:bnk_engines/bnk_engines.dart';
import 'package:flutter/material.dart';

import '../engines.dart';
import '../import.dart';
import '../observe.dart';
import '../theme.dart';
import '../widgets.dart';

/// Is anything wrong right now, and where.
class OverviewScreen extends StatefulWidget {
  const OverviewScreen({super.key});

  @override
  State<OverviewScreen> createState() => _OverviewScreenState();
}

class _OverviewScreenState extends State<OverviewScreen> {
  String? _scannedGeneration;

  /// Rescans when any cluster's probe answers, not only when the list
  /// changes.
  String _generation(ClusterStore store) => store.clusters.map((c) => '${c.id}#${c.probeGeneration}').join(',');

  @override
  Widget build(BuildContext context) {
    final engines = Engines.of(context);
    final store = engines.store;
    final overview = engines.overview;
    return Observe([store, overview, ...store.clusters], builder: (context) {
      final generation = _generation(store);
      if (_scannedGeneration != generation) {
        _scannedGeneration = generation;
        WidgetsBinding.instance.addPostFrameCallback((_) => overview.scan(store.clusters));
      }
      final scannedAt = overview.scannedAt;
      return Column(children: [
        Toolbar(title: 'Overview', children: [
          if (scannedAt != null)
            Flexible(
              child: Text('scanned ${_time(scannedAt)}',
                  style: Tokens.mono(11.5, color: Tokens.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          const Spacer(),
          if (overview.scanning) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          if (overview.scanning) const SizedBox(width: 12),
          OutlinedButton(
            onPressed: overview.scanning
                ? null
                : () async {
                    await store.probeAll();
                    await overview.scan(store.clusters);
                  },
            child: const Text('Rescan'),
          ),
        ]),
        Expanded(
          child: store.clusters.isEmpty
              // The button is here rather than a sentence pointing at another
              // screen. A screen that is empty should offer the thing that
              // fills it.
              ? Message(
                  title: 'No clusters yet',
                  detail: 'Import a kubeconfig and this will tell you whether anything is wrong. It reads every context in the file.',
                  action: FilledButton(
                    onPressed: () => importKubeconfigs(context, store),
                    child: const Text('Import kubeconfig'),
                  ),
                )
              : ListView(padding: const EdgeInsets.all(20), children: [
                  for (final report in overview.reports) ...[
                    _ReportCard(
                      report: report,
                      // Both halves. Selecting alone changed a highlight in
                      // the sidebar and left this screen where it was.
                      onSelect: () {
                        store.selected = report.id;
                        engines.navigator.section = Section.cluster;
                      },
                      onOpen: (finding) {
                        store.selected = report.id;
                        engines.navigator.revealPod(finding.pod ?? '', namespace: finding.namespace);
                      },
                    ),
                    const SizedBox(height: 14),
                  ],
                  if (overview.reports.isEmpty && !overview.scanning)
                    Padding(
                      padding: const EdgeInsets.only(top: 40),
                      child: Text('Nothing scanned yet.', style: Tokens.text(13, color: Tokens.muted), textAlign: TextAlign.center),
                    ),
                ]),
        ),
      ]);
    });
  }

  static String _time(DateTime t) {
    final local = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }
}

Color _tone(Severity severity) => switch (severity) {
      Severity.healthy => Tokens.ok,
      Severity.warning => Tokens.warn,
      Severity.critical => Tokens.bad,
    };

class _ReportCard extends StatelessWidget {
  final ClusterReport report;
  final VoidCallback onSelect;
  final void Function(Finding) onOpen;
  const _ReportCard({required this.report, required this.onSelect, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final tone = _tone(report.severity);
    return Panel(
      borderColor: report.severity == Severity.critical ? Tokens.bad.withValues(alpha: 0.3) : Tokens.border,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          StatusDot(color: tone, glow: report.severity == Severity.healthy, size: 9),
          const SizedBox(width: 11),
          Flexible(child: Text(report.cluster, style: Tokens.text(16, weight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 11),
          Pill(report.headline, color: tone),
          const Spacer(),
          if (report.nodes.isNotEmpty) ...[
            Text(report.nodes, style: Tokens.mono(11.5, color: Tokens.muted)),
            const SizedBox(width: 11),
          ],
          OutlinedButton(onPressed: onSelect, child: const Text('Open')),
        ]),
        const SizedBox(height: 12),
        if (report.findings.isEmpty)
          Inset(
            child: Row(children: [
              const Icon(Icons.check_circle_outline, size: 16, color: Tokens.ok),
              const SizedBox(width: 9),
              Expanded(
                child: Text('Every pod is running and ready, and nothing has warned in the last half hour.',
                    style: Tokens.text(12.5, color: Tokens.muted)),
              ),
            ]),
          )
        else
          for (final finding in report.findings) ...[
            _FindingRow(finding: finding, onOpen: finding.pod != null ? () => onOpen(finding) : null),
            if (finding != report.findings.last) const SizedBox(height: 8),
          ],
      ]),
    );
  }
}

class _FindingRow extends StatelessWidget {
  final Finding finding;

  /// Where this row leads, when it leads anywhere. A chevron on a row that
  /// goes nowhere is a promise the screen cannot keep.
  final VoidCallback? onOpen;
  const _FindingRow({required this.finding, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final tone = _tone(finding.severity);
    final critical = finding.severity == Severity.critical;
    final namespace = finding.namespace;
    final row = Inset(
      color: critical ? Tokens.bad.withValues(alpha: 0.05) : Tokens.bg,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 16, child: Icon(critical ? Icons.report_outlined : Icons.warning_amber_rounded, size: 15, color: tone)),
        const SizedBox(width: 11),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(finding.title, style: Tokens.mono(12.5), maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 3),
            Text(finding.detail, style: Tokens.text(12, color: Tokens.muted)),
          ]),
        ),
        if (namespace != null) ...[
          const SizedBox(width: 11),
          Text(namespace, style: Tokens.mono(11, color: Tokens.faint), maxLines: 1),
        ],
        if (onOpen != null) ...[
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right, size: 14, color: Tokens.faint),
        ],
      ]),
    );
    if (onOpen == null) return row;
    return InkWell(onTap: onOpen, borderRadius: BorderRadius.circular(9), child: row);
  }
}
