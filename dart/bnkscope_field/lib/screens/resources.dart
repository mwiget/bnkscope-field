import 'package:bnk_engines/bnk_engines.dart';
import 'package:bnk_kit/bnk_kit.dart';
import 'package:flutter/material.dart';

import '../engines.dart';
import '../observe.dart';
import '../theme.dart';
import '../widgets.dart';

/// Browsing what is on a cluster, one kind at a time.
class ResourcesScreen extends StatefulWidget {
  const ResourcesScreen({super.key});

  @override
  State<ResourcesScreen> createState() => _ResourcesScreenState();
}

class _ResourcesScreenState extends State<ResourcesScreen> {
  final _search = TextEditingController();
  String? _startedFor;
  RevealRequest? _honoured;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engines = Engines.of(context);
    final store = engines.store;
    final resources = engines.resources;
    final navigator = engines.navigator;
    final cluster = store.current;
    return Observe([store, resources, navigator, if (cluster != null) cluster], builder: (context) {
      final key = '${store.selected ?? ''}#${cluster?.probeGeneration ?? 0}';
      if (_startedFor != key) {
        _startedFor = key;
        WidgetsBinding.instance.addPostFrameCallback((_) => _start(store, resources, navigator));
      }
      // Another screen may have sent us here to look at one object.
      final pending = navigator.pending;
      if (pending != null && pending != _honoured) {
        _honoured = pending;
        WidgetsBinding.instance.addPostFrameCallback((_) => _honour(store, resources, navigator, pending));
      }
      if (_search.text != resources.query) _search.text = resources.query;
      return Column(children: [
        Toolbar(title: 'Resources', children: [
          Text('${resources.visible.length} of ${resources.objects.length}', style: Tokens.mono(11.5, color: Tokens.muted)),
          const Spacer(),
          SearchField(controller: _search, width: 180, onChanged: (v) => resources.query = v),
          if (resources.loading) ...[
            const SizedBox(width: 12),
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ]),
        _filters(store, resources),
        const Divider(height: 1, thickness: 1, color: Tokens.border),
        Expanded(child: _content(store, resources)),
      ]);
    });
  }

  Widget _filters(ClusterStore store, ResourceEngine resources) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
        child: Row(children: [
          ChipMenu(
            resources.kind.name,
            active: true,
            items: [for (final k in ResourceKind.all) menuItem(k.plural, k.name)],
            onSelected: (plural) {
              resources.kind = ResourceKind.all.firstWhere((k) => k.plural == plural);
              _reload(store, resources);
            },
          ),
          if (resources.kind.namespaced) ...[
            const SizedBox(width: 9),
            ChipMenu(
              resources.namespace ?? 'all namespaces',
              active: resources.namespace != null,
              items: [
                menuItem('', 'All namespaces'),
                const PopupMenuDivider(),
                for (final ns in resources.namespaces) menuItem(ns, ns),
              ],
              onSelected: (ns) {
                resources.namespace = ns.isEmpty ? null : ns;
                _reload(store, resources);
              },
            ),
          ],
          const Spacer(),
          OutlinedButton(onPressed: resources.loading ? null : () => _reload(store, resources), child: const Text('Reload')),
        ]),
      );

  Widget _content(ClusterStore store, ResourceEngine resources) {
    if (store.current == null) {
      return const Message(title: 'No cluster selected', detail: 'Pick a cluster in the sidebar to browse what is on it.');
    }
    final failure = resources.failure;
    if (failure != null) {
      return Message(title: 'Could not list ${resources.kind.name}', detail: failure, tone: Tokens.bad);
    }
    final visible = resources.visible;
    if (visible.isEmpty) {
      return Message(
        title: resources.loading ? 'Reading…' : 'Nothing here',
        detail: resources.query.isEmpty
            ? 'No ${resources.kind.name.toLowerCase()} in this namespace.'
            : 'Nothing matches “${resources.query}”.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(20),
      itemCount: visible.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (context, i) => _ResourceRow(
        object: visible[i],
        kind: resources.kind,
        showNamespace: resources.namespace == null,
        onOpen: () => _open(context, visible[i], resources.kind),
      ),
    );
  }

  Future<void> _start(ClusterStore store, ResourceEngine resources, ScreenNavigator navigator) async {
    final cluster = store.current;
    if (cluster == null) return;
    await resources.loadNamespaces(cluster);
    // A pending request decides what to load; loading the default first
    // would be a wasted round trip and a visible flicker.
    if (navigator.pending == null) await resources.load(cluster);
  }

  /// Show the object another screen asked for, and open it. Without this,
  /// Overview could name a broken pod and do nothing about it.
  Future<void> _honour(ClusterStore store, ResourceEngine resources, ScreenNavigator navigator, RevealRequest request) async {
    final cluster = store.current;
    if (cluster == null) return;
    final kind = ResourceKind.all.where((k) => k.plural == request.kind).firstOrNull;
    if (kind != null) resources.kind = kind;
    resources.namespace = request.namespace;
    resources.query = '';
    await resources.load(cluster);
    navigator.clear();
    final object = resources.objects.where((o) => o.name == request.name).firstOrNull;
    if (object != null && mounted) await _open(context, object, resources.kind);
  }

  Future<void> _reload(ClusterStore store, ResourceEngine resources) async {
    final cluster = store.current;
    if (cluster != null) await resources.load(cluster);
  }

  /// A page-sized sheet, not a small card: a pod's event list and its YAML
  /// are both things you read, and reading them through a letterbox is
  /// worse than not having them.
  Future<void> _open(BuildContext context, RawObject object, ResourceKind kind) => showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: Tokens.bg,
          insetPadding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 900),
            child: _ObjectDetail(object: object, kind: kind),
          ),
        ),
      );
}

class _ResourceRow extends StatelessWidget {
  final RawObject object;
  final ResourceKind kind;
  final bool showNamespace;
  final VoidCallback onOpen;
  const _ResourceRow({required this.object, required this.kind, required this.showNamespace, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final summary = ResourceSummary.line(object, kind);
    final dot = switch (summary.tone) {
      SummaryTone.good => Tokens.ok,
      SummaryTone.bad => Tokens.warn,
      SummaryTone.neutral => Tokens.muted,
    };
    final created = object.created;
    final namespace = object.namespace;
    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: Tokens.card, borderRadius: BorderRadius.circular(9), border: Border.all(color: Tokens.border)),
        child: Row(children: [
          StatusDot(color: dot),
          const SizedBox(width: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Text(object.name, style: Tokens.mono(12.5), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (showNamespace && namespace != null) ...[
            const SizedBox(width: 12),
            SizedBox(width: 150, child: Text(namespace, style: Tokens.mono(11, color: Tokens.faint), maxLines: 1, overflow: TextOverflow.ellipsis)),
          ],
          const SizedBox(width: 12),
          Expanded(
            child: Text(summary.text,
                style: Tokens.mono(11.5, color: summary.tone == SummaryTone.bad ? Tokens.warn : Tokens.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          if (created != null) ...[
            const SizedBox(width: 8),
            Text(relative(created), style: Tokens.mono(11, color: Tokens.faint), maxLines: 1),
          ],
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right, size: 14, color: Tokens.faint),
        ]),
      ),
    );
  }
}

/// One object, close up: what is wrong with it, then what it says it is.
class _ObjectDetail extends StatefulWidget {
  final RawObject object;
  final ResourceKind kind;
  const _ObjectDetail({required this.object, required this.kind});

  @override
  State<_ObjectDetail> createState() => _ObjectDetailState();
}

class _ObjectDetailState extends State<_ObjectDetail> {
  bool _yaml = false;
  bool _loaded = false;

  @override
  Widget build(BuildContext context) {
    final engines = Engines.of(context);
    final resources = engines.resources;
    if (!_loaded) {
      _loaded = true;
      final cluster = engines.store.current;
      if (cluster != null) WidgetsBinding.instance.addPostFrameCallback((_) => resources.loadEvents(widget.object, cluster));
    }
    return Observe([resources], builder: (context) {
      return Column(children: [
        Container(
          height: 60,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Tokens.border))),
          child: Row(children: [
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.object.name, style: Tokens.mono(14, weight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
                Text([widget.kind.name, widget.object.namespace].nonNulls.join(' · '), style: Tokens.mono(11, color: Tokens.muted)),
              ]),
            ),
            const SizedBox(width: 12),
            SegmentedButton<bool>(
              segments: const [ButtonSegment(value: false, label: Text('Events')), ButtonSegment(value: true, label: Text('YAML'))],
              selected: {_yaml},
              showSelectedIcon: false,
              style: ButtonStyle(visualDensity: VisualDensity.compact, textStyle: WidgetStatePropertyAll(Tokens.text(12.5, weight: FontWeight.w600))),
              onSelectionChanged: (s) => setState(() => _yaml = s.first),
            ),
            const SizedBox(width: 12),
            OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
          ]),
        ),
        Expanded(child: _yaml ? _yamlView() : _events(resources)),
      ]);
    });
  }

  Widget _events(ResourceEngine resources) {
    final events = resources.events;
    return ListView(padding: const EdgeInsets.all(20), children: [
      if (events.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 40),
          child: Text(resources.loadingEvents ? 'Reading…' : 'Nothing has been said about this object.',
              style: Tokens.text(13, color: Tokens.muted), textAlign: TextAlign.center),
        ),
      for (final event in events) ...[
        Panel(
          padding: const EdgeInsets.all(13),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(event.type == 'Warning' ? Icons.warning_amber_rounded : Icons.info_outline,
                size: 14, color: event.type == 'Warning' ? Tokens.warn : Tokens.muted),
            const SizedBox(width: 11),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text(event.reason ?? '—', style: Tokens.mono(12)),
                  if ((event.count ?? 0) > 1) ...[const SizedBox(width: 8), Pill('×${event.count}')],
                  const Spacer(),
                  if (event.at case final at?) Text(relative(at), style: Tokens.mono(10.5, color: Tokens.faint)),
                ]),
                const SizedBox(height: 3),
                Text(OverviewEngine.tidy(event.message ?? ''), style: Tokens.text(12, color: Tokens.muted)),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 6),
      ],
    ]);
  }

  Widget _yamlView() => Container(
        color: const Color(0xFF0B0D11),
        child: SingleChildScrollView(
          scrollDirection: Axis.vertical,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(20),
            child: SelectableText(widget.object.yaml, style: Tokens.mono(11.5, color: const Color(0xFFB6BCCB))),
          ),
        ),
      );
}
