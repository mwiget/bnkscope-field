import 'package:bnk_engines/bnk_engines.dart';
import 'package:bnk_kit/bnk_kit.dart';
import 'package:flutter/material.dart';

import '../engines.dart';
import '../observe.dart';
import '../theme.dart';
import '../widgets.dart';

enum ExporterStyle {
  /// The full targets list, shown under a working dashboard.
  card,

  /// The whole screen, when there is nothing to scrape yet.
  prompt,
}

/// The exporter's state, and what can be done about it, on the screen that
/// depends on it.
///
/// This used to be a separate Telemetry item in the menu, which put a thing
/// you configure beside seven things you look at. Worse, it split one
/// subject in two: TMM Live listed which pods carried the exporter and could
/// do nothing, while another screen could act but showed no graphs. The
/// state and the actions belong together, on the screen that is empty
/// without them.
class ExporterPanel extends StatefulWidget {
  final ExporterStyle style;
  const ExporterPanel({super.key, required this.style});

  @override
  State<ExporterPanel> createState() => _ExporterPanelState();
}

class _ExporterPanelState extends State<ExporterPanel> {
  bool _busy = false;
  List<String> _owners = const [];
  String? _ownersFor;

  List<Pod> _pods(ClusterStore store) => store.current?.tmmPods ?? const [];
  List<Pod> _missing(ClusterStore store) =>
      _pods(store).where((p) => Exporter.installation(p) is AbsentInstallation).toList();
  List<Pod> _ephemeral(ClusterStore store) =>
      _pods(store).where((p) => Exporter.installation(p) is EphemeralInstallation).toList();
  List<Pod> _permanent(ClusterStore store) =>
      _pods(store).where((p) => Exporter.installation(p) is PermanentInstallation).toList();

  @override
  Widget build(BuildContext context) {
    final engines = Engines.of(context);
    final store = engines.store;
    final cluster = store.current;
    return Observe([store, engines.telemetry, if (cluster != null) cluster], builder: (context) {
      final key = '${store.selected ?? ''}#${cluster?.probeGeneration ?? 0}';
      if (_ownersFor != key) {
        _ownersFor = key;
        WidgetsBinding.instance.addPostFrameCallback((_) => _findOwners(store));
      }
      return switch (widget.style) {
        ExporterStyle.card => _targetsCard(context, store, engines.telemetry),
        ExporterStyle.prompt => _installPrompt(context, store),
      };
    });
  }

  // The empty case

  Widget _installPrompt(BuildContext context, ClusterStore store) {
    final pods = _pods(store);
    final missing = _missing(store);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 470),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(missing.isEmpty ? 'Exporter added' : 'Nothing to scrape here', style: Tokens.text(17, weight: FontWeight.w600)),
          const SizedBox(height: 14),
          Text(
            missing.isEmpty
                ? 'The exporter is in. TMM Live is starting up — the first samples arrive within a scrape or two.'
                : '${missing.length} of ${pods.length} f5-tmm pod${pods.length == 1 ? '' : 's'} on this cluster carry no exporter. '
                    'Adding it attaches an ephemeral container that reads the tmstat segment read-only and serves /metrics. '
                    'TMM keeps running — nothing restarts.',
            style: Tokens.text(13, color: Tokens.muted),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
          if (missing.isNotEmpty)
            FilledButton(onPressed: _busy ? null : () => _install(store), child: Text(_busy ? 'Adding…' : 'Add the exporter'))
          else
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(height: 14),
          Text('It is gone again when a pod is recreated, and nothing re-adds it.', style: Tokens.text(11.5, color: Tokens.faint)),
        ]),
      ),
    );
  }

  // The working case

  Widget _targetsCard(BuildContext context, ClusterStore store, TelemetryEngine engine) {
    final missing = _missing(store);
    final ephemeral = _ephemeral(store);
    final permanent = _permanent(store);
    return Panel(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('Exporter targets', style: Tokens.text(13.5, weight: FontWeight.w600)),
          const SizedBox(width: 10),
          Text(Exporter.containerName, style: Tokens.mono(11, color: Tokens.muted)),
          const Spacer(),
          if (_busy)
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
          else ...[
            if (missing.isNotEmpty)
              FilledButton(
                onPressed: () => _install(store),
                child: Text('Add to ${missing.length} pod${missing.length == 1 ? '' : 's'}'),
              ),
            if (ephemeral.isNotEmpty) ...[
              const SizedBox(width: 8),
              OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: Tokens.bad, side: BorderSide(color: Tokens.bad.withValues(alpha: 0.4))),
                onPressed: () => _confirmRemoval(context, store, engine, ephemeral),
                child: const Text('Remove…'),
              ),
            ],
          ],
        ]),
        for (final pod in _pods(store)) ...[
          const SizedBox(height: 10),
          _TargetRow(pod: pod, status: engine.podStatus[pod.metadata.name]),
        ],
        if (permanent.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            _owners.isEmpty
                ? "Defined in the workload's pod template, so this app cannot remove it."
                : 'Defined in ${_owners.join(', ')} — removing it means editing that, not deleting pods.',
            style: Tokens.text(11.5, color: Tokens.faint),
          ),
        ],
      ]),
    );
  }

  // Doing it

  Future<void> _install(ClusterStore store) async {
    final cluster = store.current;
    if (cluster == null) return;
    final KubeClient client;
    try {
      client = cluster.client();
    } catch (e) {
      // Returning quietly here is indistinguishable from a tap that did
      // nothing, which is what a silent failure looks like from the far side
      // of the screen.
      await _report('Could not reach the cluster', [brief(e)], bad: true);
      return;
    }
    setState(() => _busy = true);
    final outcome = await Exporter.install(_missing(store), clusterLabel: cluster.displayName, client: client);
    await cluster.probeReflectingChange();
    if (mounted) setState(() => _busy = false);
    await _report(outcome.failed.isEmpty ? 'Exporter added' : 'Exporter partly added', _summarise(outcome, 'added to'),
        bad: outcome.failed.isNotEmpty);
  }

  Future<void> _confirmRemoval(BuildContext context, ClusterStore store, TelemetryEngine engine, List<Pod> ephemeral) async {
    final name = store.current?.displayName ?? 'the cluster name';
    final typed = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, setDialogState) {
        return AlertDialog(
          title: const Text('Recreate the TMM pods?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('An ephemeral container cannot be taken out of a running pod. Removing the exporter means deleting '
                '${ephemeral.length} f5-tmm pod${ephemeral.length == 1 ? '' : 's'} so they are rebuilt without it. '
                'Dataplane traffic through those pods stops until they are back.\n\nType $name to confirm.'),
            const SizedBox(height: 12),
            TextField(
              controller: typed,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(hintText: 'cluster name', isDense: true, border: OutlineInputBorder()),
              style: Tokens.mono(13),
              onChanged: (_) => setDialogState(() {}),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Tokens.bad),
              onPressed: typed.text == name ? () => Navigator.of(context).pop(true) : null,
              child: const Text('Recreate pods and remove'),
            ),
          ],
        );
      }),
    );
    typed.dispose();
    if (confirmed == true) await _remove(store, engine, ephemeral);
  }

  Future<void> _remove(ClusterStore store, TelemetryEngine engine, List<Pod> ephemeral) async {
    final cluster = store.current;
    if (cluster == null) return;
    final KubeClient client;
    try {
      client = cluster.client();
    } catch (e) {
      await _report('Could not reach the cluster', [brief(e)], bad: true);
      return;
    }
    setState(() => _busy = true);
    engine.stop();
    final outcome = await Exporter.remove(ephemeral, client: client);
    await cluster.probeReflectingChange();
    if (mounted) setState(() => _busy = false);
    await _report(outcome.failed.isEmpty ? 'Pods recreated' : 'Removal incomplete', _summarise(outcome, 'recreated'),
        bad: outcome.failed.isNotEmpty);
  }

  Future<void> _findOwners(ClusterStore store) async {
    final cluster = store.current;
    final client = cluster?.clientOrNull;
    if (cluster == null || client == null) {
      if (mounted) setState(() => _owners = const []);
      return;
    }
    final found = <String>{};
    for (final pod in _permanent(store)) {
      final owner = await Exporter.owner(pod, client);
      if (owner != null) found.add(owner);
    }
    if (mounted) setState(() => _owners = found.toList()..sort());
  }

  List<String> _summarise(ExporterOutcome outcome, String verb) {
    final lines = <String>[];
    if (outcome.changed.isNotEmpty) {
      lines.add('$verb ${outcome.changed.length} pod(s):\n  ${outcome.changed.join('\n  ')}');
    }
    if (outcome.skipped.isNotEmpty) lines.add('skipped ${outcome.skipped.length}, already as wanted');
    for (final f in outcome.failed) {
      lines.add('${f.pod}: ${f.reason}');
    }
    return lines.isEmpty ? ['Nothing changed.'] : lines;
  }

  Future<void> _report(String title, List<String> lines, {required bool bad}) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 420),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(line, style: Tokens.mono(12.5, color: bad ? Tokens.warn : Tokens.muted)),
              ),
          ]),
        ),
        actions: [FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done'))],
      ),
    );
  }
}

/// One exporter target: whether it is answering, and how it got there.
class _TargetRow extends StatelessWidget {
  final Pod pod;
  final ScrapeStatus? status;
  const _TargetRow({required this.pod, required this.status});

  @override
  Widget build(BuildContext context) {
    final installation = Exporter.installation(pod);
    final absent = installation is AbsentInstallation;
    final dot = switch (status) {
      Answering() => Tokens.ok,
      Failing() => Tokens.bad,
      null => absent ? Tokens.warn : Tokens.muted,
    };
    final detail = switch (status) {
      Answering(:final samples) => '$samples samples · ${Exporter.runningImage(pod) ?? 'exporter'}',
      Failing(:final why) => why,
      null => absent ? 'no exporter in this pod' : (Exporter.runningImage(pod) ?? 'exporter present, not scraped yet'),
    };
    return Inset(
      child: Row(children: [
        StatusDot(color: dot, glow: status is Answering),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(pod.metadata.name, style: Tokens.mono(12), maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 3),
            Text(detail, style: Tokens.mono(10.5, color: status is Failing ? Tokens.warn : Tokens.faint), maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
        const SizedBox(width: 8),
        Text(pod.node, style: Tokens.mono(11.5, color: Tokens.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
        if (installation is EphemeralInstallation) ...[
          const SizedBox(width: 8),
          const Pill('ephemeral', color: Tokens.warn),
        ],
      ]),
    );
  }
}
