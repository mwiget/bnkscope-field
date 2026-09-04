import 'package:bnk_engines/bnk_engines.dart';
import 'package:bnk_kit/bnk_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engines.dart';
import '../observe.dart';
import '../theme.dart';
import '../widgets.dart';

/// The TMM diagnostics, run in a container over exec.
class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  /// The diagnostics this exists for. Columns were checked against a live
  /// tmm pod rather than guessed, and trimmed to fit 80 characters: tmctl
  /// wraps its table into stacked blocks beyond that, and with no TTY there
  /// is nothing to tell it otherwise.
  static const debugTools = <(String, List<String>)>[
    ('cpu', ['tmctl', '-d', 'blade', 'tmm_stat', '-s', 'pid,cpu,polls,idle_polls']),
    ('connections', ['tmctl', '-d', 'blade', 'tmm_stat', '-s', 'client_side_traffic.cur_conns,client_side_traffic.tot_conns']),
    ('virtual servers', ['tmctl', '-d', 'blade', 'virtual_server_stat', '-s', 'name,clientside.tot_conns']),
    ('interfaces', ['tmctl', '-d', 'blade', 'interface_stat', '-s', 'name,counters.bytes_in,counters.bytes_out']),
    ('memory', ['tmctl', '-d', 'blade', 'memory_usage_stat', '-s', 'name,allocated,size']),
    ('ip -s link', ['ip', '-s', 'link']),
  ];

  /// The same idea for the routing container, where ZebOS lives. `imish` is
  /// an interactive shell and exec here has no TTY, so `-e` runs one command
  /// and exits, repeated to build a session.
  static const routingTools = <(String, List<String>)>[
    ('bgp summary', ['imish', '-e', 'en', '-e', 'show ip bgp summary']),
    ('bgp neighbors', ['imish', '-e', 'en', '-e', 'show ip bgp neighbors']),
    ('routes', ['imish', '-e', 'en', '-e', 'show ip route bgp']),
    ('bfd', ['imish', '-e', 'en', '-e', 'show bfd interface']),
    ('running-config', ['imish', '-e', 'en', '-e', 'show running-config bgp']),
  ];

  /// ZebOS ships as `f5-tmm-routing` on BNK, but the name is matched loosely
  /// rather than pinned: the same container is called zebos or ocnos in
  /// other builds, and a wrong guess only costs the shortcuts, not the shell.
  static bool _isRouting(String container) {
    final name = container.toLowerCase();
    return name.contains('routing') || name.contains('zebos') || name.contains('ocnos');
  }

  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  String? _podName;
  String? _container;
  String? _selectedFor;
  int _lastLineCount = -1;

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engines = Engines.of(context);
    final store = engines.store;
    final exec = engines.exec;
    final cluster = store.current;
    return Observe([store, exec, if (cluster != null) cluster], builder: (context) {
      if (_selectedFor != (store.selected ?? '')) {
        _selectedFor = store.selected ?? '';
        _podName = null;
        _container = null;
        WidgetsBinding.instance.addPostFrameCallback((_) => exec.clear());
      }
      final pods = cluster?.tmmPods ?? const <Pod>[];
      final pod = pods.where((p) => p.metadata.name == _podName).firstOrNull ?? pods.firstOrNull;
      final containers = pod?.logSources ?? const <String>[];
      final tool = _toolContainer(containers);
      final quick = _isRouting(tool) ? routingTools : debugTools;
      final lines = exec.runs.isEmpty ? 0 : exec.runs.last.lines.length + exec.runs.length * 1000;
      if (lines != _lastLineCount) {
        _lastLineCount = lines;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
        });
      }
      return Column(children: [
        Toolbar(title: 'Terminal', children: [
          Text('exec · v5.channel.k8s.io', style: Tokens.mono(11.5, color: Tokens.muted)),
          const Spacer(),
          if (exec.running) ...[OutlinedButton(onPressed: exec.cancel, child: const Text('Stop')), const SizedBox(width: 8)],
          OutlinedButton(onPressed: exec.clear, child: const Text('Clear')),
        ]),
        if (cluster == null)
          const Expanded(child: Message(title: 'No cluster selected', detail: 'Pick a cluster in the sidebar to run a diagnostic in one of its TMM pods.'))
        else if (pods.isEmpty || pod == null)
          const Expanded(child: Message(title: 'No f5-tmm pods here', detail: 'This screen runs the TMM diagnostics, so it needs a cluster running BNK.'))
        else ...[
          _targetBar(exec, pods, pod, containers, tool, quick),
          const Divider(height: 1, thickness: 1, color: Tokens.border),
          Expanded(child: _output(exec)),
          const Divider(height: 1, thickness: 1, color: Tokens.border),
          _prompt(exec, pod, tool, quick),
        ],
      ]);
    });
  }

  /// Which container the commands run in: `debug` when there is one, since
  /// `tmctl` lives there, and the picker is what lets `imish` be reached in
  /// the routing container.
  String _toolContainer(List<String> containers) {
    final chosen = _container;
    if (chosen != null && containers.contains(chosen)) return chosen;
    return containers.contains('debug') ? 'debug' : (containers.firstOrNull ?? 'debug');
  }

  Widget _targetBar(ExecEngine exec, List<Pod> pods, Pod pod, List<String> containers, String tool, List<(String, List<String>)> quick) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            ChipMenu(
              shortPodName(pod.metadata.name),
              items: [for (final p in pods) menuItem(p.metadata.name, p.metadata.name)],
              onSelected: (name) => setState(() {
                _podName = name;
                _container = null;
              }),
            ),
            const SizedBox(width: 9),
            if (containers.length > 1)
              ChipMenu(tool, items: [for (final c in containers) menuItem(c, c)], onSelected: (c) => setState(() => _container = c))
            else
              Choice(tool),
            const SizedBox(width: 9),
            Container(width: 1, height: 18, color: Tokens.border),
            for (final (label, command) in quick) ...[
              const SizedBox(width: 9),
              Choice(label, onTap: exec.running ? null : () => _runCommand(exec, pod, command, tool)),
            ],
          ]),
        ),
      );

  Widget _output(ExecEngine exec) => Container(
        color: const Color(0xFF0B0D11),
        child: ListView(controller: _scroll, padding: const EdgeInsets.symmetric(vertical: 12), children: [
          if (exec.runs.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Text('Pick a diagnostic above, or type a command.', style: Tokens.mono(12.5, color: Tokens.faint)),
            ),
          for (final run in exec.runs) _RunBlock(key: ValueKey(run.id), run: run),
        ]),
      );

  Widget _prompt(ExecEngine exec, Pod pod, String tool, List<(String, List<String>)> quick) {
    final completion = _completion(exec, quick);
    return Container(
      color: Tokens.card,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(children: [
        Text(tool, style: Tokens.mono(11.5, color: Tokens.faint)),
        const SizedBox(width: 10),
        Text(r'$', style: Tokens.mono(13, weight: FontWeight.w600, color: Tokens.ok)),
        const SizedBox(width: 10),
        Expanded(
          child: Stack(alignment: Alignment.centerLeft, children: [
            // The suggestion is drawn behind the field, with the part
            // already typed rendered clear so its tail begins exactly at the
            // caret rather than near it.
            if (completion != null)
              IgnorePointer(
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: _input.text, style: Tokens.mono(13, color: Colors.transparent)),
                  TextSpan(text: completion, style: Tokens.mono(13, color: Tokens.faint)),
                ]), maxLines: 1, overflow: TextOverflow.clip),
              ),
            Focus(
              onKeyEvent: (node, event) {
                // Tab is the habit this borrows from; the focus system must
                // not take it first.
                if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.tab && completion != null) {
                  _accept(completion);
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: TextField(
                controller: _input,
                focusNode: _focus,
                autocorrect: false,
                enableSuggestions: false,
                style: Tokens.mono(13),
                decoration: const InputDecoration.collapsed(hintText: ''),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _submit(exec, pod, tool),
              ),
            ),
          ]),
        ),
        if (completion != null) ...[
          const SizedBox(width: 10),
          // An iPad without a keyboard has no Tab key, so the hint is also
          // the button.
          Tooltip(
            message: 'Accept the suggested command',
            child: InkWell(
              onTap: () => _accept(completion),
              borderRadius: BorderRadius.circular(5),
              child: Container(
                height: 22,
                padding: const EdgeInsets.symmetric(horizontal: 7),
                decoration: BoxDecoration(color: Tokens.secondary, borderRadius: BorderRadius.circular(5), border: Border.all(color: Tokens.border)),
                child: Center(child: Text('tab ⇥', style: Tokens.mono(10.5, weight: FontWeight.w600, color: Tokens.muted))),
              ),
            ),
          ),
        ],
        const SizedBox(width: 10),
        FilledButton(onPressed: _input.text.trim().isEmpty || exec.running ? null : () => _submit(exec, pod, tool), child: const Text('Run')),
      ]),
    );
  }

  /// What Tab would add: the tail of the first suggestion that extends what
  /// has been typed. An empty line suggests this container's first
  /// diagnostic, which a placeholder used to do badly: it could not be
  /// accepted and vanished at the first keystroke.
  String? _completion(ExecEngine exec, List<(String, List<String>)> quick) {
    final input = _input.text;
    if (input.isEmpty) return quick.isEmpty ? null : Argv.join(quick.first.$2);
    // Commands already run, most recent first, then this container's own
    // diagnostics: re-running what was just run is the common case.
    final seen = <String>{};
    final suggestions = [
      for (final run in exec.runs.reversed) run.command,
      for (final q in quick) Argv.join(q.$2),
    ].where(seen.add);
    for (final s in suggestions) {
      if (s.startsWith(input) && s.length > input.length) return s.substring(input.length);
    }
    return null;
  }

  void _accept(String completion) {
    _input.text = _input.text + completion;
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    _focus.requestFocus();
    setState(() {});
  }

  void _submit(ExecEngine exec, Pod pod, String tool) {
    // Quotes are honoured, because imish takes a whole ZebOS command as one
    // argument. Pipes and redirection still are not: there is no shell on
    // the far side of exec.
    final parts = Argv.split(_input.text);
    if (parts.isEmpty) return;
    _input.clear();
    _runCommand(exec, pod, parts, tool);
  }

  void _runCommand(ExecEngine exec, Pod pod, List<String> command, String container) {
    final cluster = Engines.of(context).store.current;
    final client = cluster?.clientOrNull;
    final namespace = pod.metadata.namespace;
    if (client == null || namespace == null) return;
    exec.run(command, container: container, namespace: namespace, pod: pod.metadata.name, client: client);
    setState(() {});
  }
}

class _RunBlock extends StatelessWidget {
  final ExecRun run;
  const _RunBlock({super.key, required this.run});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(r'$', style: Tokens.mono(12.5, weight: FontWeight.w600, color: Tokens.ok)),
            const SizedBox(width: 8),
            Flexible(child: Text(run.command, style: Tokens.mono(12.5), maxLines: 1, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 8),
            Text(run.container, style: Tokens.mono(10.5, color: Tokens.faint)),
            if (!run.finished) ...[const SizedBox(width: 8), const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5))],
          ]),
          const SizedBox(height: 4),
          SelectableText.rich(TextSpan(children: [
            for (final line in run.lines)
              TextSpan(text: '${line.text.isEmpty ? ' ' : line.text}\n', style: Tokens.mono(12.5, color: line.isError ? Tokens.warn : const Color(0xFFB6BCCB))),
          ])),
          if (run.failure case final failure?) ...[
            const SizedBox(height: 2),
            Text(failure, style: Tokens.mono(11.5, color: Tokens.bad)),
          ],
        ]),
      );
}
