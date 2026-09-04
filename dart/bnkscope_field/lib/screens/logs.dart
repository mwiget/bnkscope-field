import 'package:bnk_engines/bnk_engines.dart';
import 'package:bnk_kit/bnk_kit.dart';
import 'package:flutter/material.dart';

import '../engines.dart';
import '../observe.dart';
import '../theme.dart';
import '../widgets.dart';
import 'tmm_live.dart';

/// Every container in one namespace, followed straight off the apiserver.
class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  final _search = TextEditingController();
  String? _namespace;
  List<String> _namespaces = const [];
  bool _loading = false;
  String? _discoveredFor;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engines = Engines.of(context);
    final store = engines.store;
    final logs = engines.logs;
    final cluster = store.current;
    return Observe([store, logs, if (cluster != null) cluster], builder: (context) {
      if (_discoveredFor != (store.selected ?? '')) {
        _discoveredFor = store.selected ?? '';
        WidgetsBinding.instance.addPostFrameCallback((_) => _discoverNamespaces(store, logs));
      } else if (_namespace == null && !_loading && _namespaces.isNotEmpty) {
        // The probe may answer after the screen opened: once it says where
        // the TMM pods are, start there without being asked.
        final tmmNamespace = store.current?.tmmPods.firstOrNull?.metadata.namespace;
        if (tmmNamespace != null && _namespaces.contains(tmmNamespace)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _namespace != null) return;
            setState(() => _namespace = tmmNamespace);
            _follow(store, logs, tmmNamespace);
          });
        }
      }
      if (_search.text != logs.query) _search.text = logs.query;
      return Column(children: [
        Toolbar(title: 'Logs', children: [
          if (logs.following.isNotEmpty) Text('${logs.following.length} containers', style: Tokens.mono(11.5, color: Tokens.muted)),
          const Spacer(),
          SearchField(controller: _search, onChanged: (v) => logs.query = v),
          if (logs.isRunning) ...[const SizedBox(width: 12), const StatePill('TAILING', tone: PillTone.live)],
        ]),
        _filters(store, logs),
        const Divider(height: 1, thickness: 1, color: Tokens.border),
        Expanded(child: _content(store, logs)),
      ]);
    });
  }

  Widget _filters(ClusterStore store, LogsEngine logs) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
        child: Row(children: [
          ChipMenu(
            _namespace ?? 'namespace',
            active: _namespace != null,
            items: [for (final ns in _namespaces) menuItem(ns, ns)],
            onSelected: (ns) {
              setState(() => _namespace = ns);
              _follow(store, logs, ns);
            },
          ),
          for (final level in LogLevel.values) ...[
            const SizedBox(width: 9),
            Choice(
              level.name,
              tint: _colour(level),
              active: logs.levels.contains(level),
              onTap: () {
                final levels = logs.levels.toSet();
                if (!levels.remove(level)) levels.add(level);
                logs.levels = levels;
              },
            ),
          ],
          const SizedBox(width: 9),
          ChipMenu(
            logs.muted.isEmpty ? 'sources' : '${logs.muted.length} muted',
            active: logs.muted.isNotEmpty,
            items: [
              if (logs.muted.isNotEmpty) ...[menuItem(' unmute', 'Unmute all'), const PopupMenuDivider()],
              for (final s in logs.sources)
                menuItem(s.container, '${s.container} — ${s.lines}', icon: logs.muted.contains(s.container) ? Icons.volume_off : Icons.check),
            ],
            onSelected: (c) {
              if (c == ' unmute') {
                for (final m in logs.muted.toList()) {
                  logs.toggleMute(m);
                }
              } else {
                logs.toggleMute(c);
              }
            },
          ),
          if (logs.dropped > 0) ...[
            const SizedBox(width: 9),
            Flexible(
              child: Text('${logs.dropped} more containers not followed',
                  style: Tokens.mono(11, color: Tokens.warn), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
          const Spacer(),
          const SizedBox(width: 9),
          Text('${logs.visible.length} of ${logs.lines.length}', style: Tokens.mono(11, color: Tokens.faint)),
          const SizedBox(width: 9),
          OutlinedButton(onPressed: logs.clear, child: const Text('Clear')),
        ]),
      );

  Widget _content(ClusterStore store, LogsEngine logs) {
    if (store.current == null) {
      return const Message(title: 'No cluster selected', detail: 'Pick a cluster in the sidebar to follow its logs.');
    }
    if (_namespace == null) {
      return Message(
          title: _loading ? 'Reading namespaces…' : 'Pick a namespace',
          detail: 'Field follows every container in one namespace at a time, straight off the apiserver. Nothing is installed to make that work.');
    }
    final visible = logs.visible;
    if (visible.isEmpty) {
      return Message(
        title: logs.isRunning ? 'Waiting for output' : 'Not following',
        detail: logs.lines.isEmpty
            ? 'Following ${logs.following.length} container${logs.following.length == 1 ? '' : 's'}. Nothing has been logged yet.'
            : '${logs.lines.length} lines held, none match the filter.',
      );
    }
    return ListView.builder(
      itemCount: visible.length,
      itemBuilder: (context, i) => _LogRow(key: ValueKey(visible[i].id), line: visible[i], onMute: logs.toggleMute),
    );
  }

  static Color _colour(LogLevel level) => switch (level) {
        LogLevel.error => Tokens.bad,
        LogLevel.warning => Tokens.warn,
        LogLevel.info => Tokens.muted,
      };

  // Wiring

  Future<void> _discoverNamespaces(ClusterStore store, LogsEngine logs) async {
    logs.stop();
    logs.clear();
    setState(() {
      _namespace = null;
      _namespaces = const [];
    });
    final cluster = store.current;
    final client = cluster?.clientOrNull;
    if (cluster == null || client == null) return;
    setState(() => _loading = true);
    List<String> namespaces = const [];
    try {
      namespaces = await client.namespaces();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _namespaces = namespaces;
      _loading = false;
    });
    // Start where the interesting pods are rather than at whatever sorts
    // first alphabetically.
    final tmmNamespace = cluster.tmmPods.firstOrNull?.metadata.namespace;
    if (tmmNamespace != null && namespaces.contains(tmmNamespace)) {
      setState(() => _namespace = tmmNamespace);
      await _follow(store, logs, tmmNamespace);
    }
  }

  Future<void> _follow(ClusterStore store, LogsEngine logs, String ns) async {
    final client = store.current?.clientOrNull;
    if (client == null) return;
    logs.clear();
    List<Pod> pods = const [];
    try {
      pods = await client.pods(namespace: ns);
    } catch (_) {}
    if (!mounted) return;
    logs.start(client: client, namespace: ns, pods: pods);
  }
}

class _LogRow extends StatefulWidget {
  final LogLine line;
  final void Function(String) onMute;
  const _LogRow({super.key, required this.line, required this.onMute});

  @override
  State<_LogRow> createState() => _LogRowState();
}

class _LogRowState extends State<_LogRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final line = widget.line;
    final colour = switch (line.level) {
      LogLevel.error => Tokens.bad,
      LogLevel.warning => Tokens.warn,
      LogLevel.info => Tokens.fg,
    };
    final container = line.container;
    final at = line.at;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
      color: line.level == LogLevel.error ? Tokens.bad.withValues(alpha: 0.05) : Colors.transparent,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 68, child: Text(at == null ? '—' : clock(at), style: Tokens.mono(11.5, color: Tokens.faint))),
        const SizedBox(width: 12),
        SizedBox(
          width: 120,
          child: Tooltip(
            message: 'Mute this container',
            child: InkWell(
              onTap: container == null ? null : () => widget.onMute(container),
              child: Text(container ?? '—', style: Tokens.mono(11, color: Tokens.muted), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(width: 150, child: Text(line.pod, style: Tokens.mono(11, color: Tokens.faint), maxLines: 1, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 12),
        // Capped, because a single openflow dump runs to twenty lines and
        // pushes everything around it off the screen. Tap to see all of it.
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _expanded = !_expanded),
            child: SelectableText(line.text, style: Tokens.mono(11.5, color: colour), maxLines: _expanded ? null : 3),
          ),
        ),
      ]),
    );
  }
}
