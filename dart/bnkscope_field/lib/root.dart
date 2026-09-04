import 'package:bnk_engines/bnk_engines.dart';
import 'package:bnk_kit/bnk_kit.dart';
import 'package:flutter/material.dart';

import 'engines.dart';
import 'import.dart';
import 'observe.dart';
import 'platform.dart';
import 'screens/cluster.dart';
import 'screens/overview.dart';
import 'screens/dpu.dart';
import 'screens/kubevirt.dart';
import 'screens/logs.dart';
import 'screens/nico.dart';
import 'screens/resources.dart';
import 'screens/terminal.dart';
import 'screens/tmm_live.dart';
import 'theme.dart';
import 'widgets.dart';

/// The split: a sidebar of clusters and their screens, and the screen.
///
/// Below [sidebarWidthThreshold] the sidebar costs more than it gives, 268
/// of chrome plus a detail column too narrow for two chart panels side by
/// side, so it becomes a drawer. On iPadOS a window is any size the user
/// drags it to, so this has to be decided from the width and not the device.
class RootView extends StatefulWidget {
  const RootView({super.key});

  static const sidebarWidthThreshold = 900.0;
  static const sidebarWidth = 268.0;

  @override
  State<RootView> createState() => _RootViewState();
}

class _RootViewState extends State<RootView> {
  final _scaffold = GlobalKey<ScaffoldState>();

  /// Whether the sidebar is shown when there is room for it. A deliberate
  /// toggle survives until the window actually changes shape.
  bool _shown = true;
  bool? _wasWide;

  @override
  Widget build(BuildContext context) {
    final engines = Engines.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= RootView.sidebarWidthThreshold;
      if (_wasWide != wide) {
        _wasWide = wide;
        _shown = wide;
      }
      return Observe([engines.store, engines.navigator], builder: (context) {
        final store = engines.store;
        final navigator = engines.navigator;
        // The screen is checked against the cluster here, where every way
        // the pair can change passes, and not only in the sidebar's own
        // tap. Probe-all and remove move the selection without it, and a
        // re-probe can take away the role a screen depends on.
        final cluster = store.current;
        if (cluster != null && navigator.section != Section.overview && !navigator.section.isAvailable(cluster)) {
          WidgetsBinding.instance.addPostFrameCallback((_) => navigator.section = Section.cluster);
        }
        final detail = _detail(navigator.section);
        final scope = SplitScope(
          sidebarShown: wide ? _shown : false,
          toggle: () {
            if (wide) {
              setState(() => _shown = !_shown);
            } else {
              _scaffold.currentState?.openDrawer();
            }
          },
          child: detail,
        );
        if (wide) {
          return Scaffold(
            key: _scaffold,
            body: Row(children: [
              if (_shown) const SizedBox(width: RootView.sidebarWidth, child: Sidebar()),
              if (_shown) const VerticalDivider(width: 1, thickness: 1, color: Tokens.border),
              Expanded(child: scope),
            ]),
          );
        }
        return Scaffold(
          key: _scaffold,
          drawer: const Drawer(width: RootView.sidebarWidth, child: Sidebar()),
          body: scope,
        );
      });
    });
  }

  Widget _detail(Section section) => switch (section) {
        Section.overview => const OverviewScreen(),
        Section.cluster => const ClusterScreen(),
        Section.tmmLive => const TMMLiveScreen(),
        Section.resources => const ResourcesScreen(),
        Section.logs => const LogsScreen(),
        Section.dpu => const DpuScreen(),
        Section.nico => const NicoScreen(),
        Section.kubevirt => const KubeVirtScreen(),
        Section.terminal => const TerminalScreen(),
      };
}

/// One outline. Overview stands alone at the top because it is the only
/// screen that reads every cluster; everything else is a screen *of* a
/// cluster, and sits under the cluster it is of.
class Sidebar extends StatefulWidget {
  const Sidebar({super.key});

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  bool _probing = false;

  /// The selected cluster, when its sections have been folded away. Only
  /// the selected cluster is ever open, so this is a single id, and it
  /// forgets itself the moment the selection moves.
  String? _folded;
  String? _lastSelected;

  @override
  Widget build(BuildContext context) {
    final engines = Engines.of(context);
    final store = engines.store;
    final navigator = engines.navigator;
    return Observe([store, navigator], builder: (context) {
      if (_lastSelected != store.selected) {
        _lastSelected = store.selected;
        _folded = null;
      }
      final wordmark = Row(mainAxisSize: MainAxisSize.min, children: [
        const BNKMark(size: 28),
        const SizedBox(width: 10),
        Flexible(child: Text('bnkscope', style: Tokens.text(16.5, weight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            color: Tokens.ember.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Tokens.ember.withValues(alpha: 0.25)),
          ),
          child: Text('FIELD', style: Tokens.mono(9.5, weight: FontWeight.w700, color: Tokens.ember).copyWith(letterSpacing: 0.9)),
        ),
      ]);
      return Material(
        color: Tokens.card,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
            child: Align(alignment: wordmarkTrailing ? Alignment.centerRight : Alignment.centerLeft, child: wordmark),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.symmetric(horizontal: 10), children: [
              SectionRow(
                section: Section.overview,
                active: navigator.section == Section.overview,
                onTap: () => _closeDrawer(() => navigator.section = Section.overview),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                child: Divider(height: 1, thickness: 1, color: Tokens.border),
              ),
              for (final cluster in store.clusters)
                _ClusterGroup(
                  cluster: cluster,
                  selected: store.selected == cluster.id,
                  expanded: store.selected == cluster.id && _folded != cluster.id,
                  active: navigator.section,
                  onHeader: () => _headerTapped(cluster),
                  onOpen: (section) => _closeDrawer(() => _select(cluster, section: section)),
                ),
            ]),
          ),
          const Divider(height: 1, thickness: 1, color: Tokens.border),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            // Wrapped, so a column too narrow for both buttons on one line
            // puts the second below rather than off the edge.
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                onPressed: () => importKubeconfigs(context, store),
                icon: const Icon(Icons.add, size: 15),
                label: const Text('Import kubeconfig'),
              ),
              OutlinedButton.icon(
                onPressed: _probing || store.clusters.isEmpty
                    ? null
                    : () async {
                        setState(() => _probing = true);
                        await store.probeAll();
                        if (mounted) setState(() => _probing = false);
                      },
                icon: const Icon(Icons.wifi, size: 15),
                label: Text(_probing ? 'Probing…' : 'Probe all'),
              ),
            ]),
          ),
        ]),
      );
    });
  }

  /// In a drawer, a choice closes it; in a column, nothing to close.
  void _closeDrawer(VoidCallback then) {
    then();
    final scaffold = Scaffold.maybeOf(context);
    if (scaffold != null && scaffold.isDrawerOpen) scaffold.closeDrawer();
  }

  /// A tap on the cluster's own row.
  ///
  /// The first tap takes you there; a second folds it. Except from Overview,
  /// where the cluster is selected but nothing of it is on screen: there a
  /// tap on the selected cluster should still open it, not hide its screens.
  void _headerTapped(ManagedCluster cluster) {
    final engines = Engines.of(context);
    if (engines.store.selected != cluster.id) return _closeDrawer(() => _select(cluster));
    if (engines.navigator.section == Section.overview) {
      _folded = null;
      _closeDrawer(() => engines.navigator.section = Section.cluster);
    } else {
      setState(() => _folded = _folded == cluster.id ? null : cluster.id);
    }
  }

  /// Make this the cluster the screens are about.
  ///
  /// The screen stays put when it can: switching from one cluster's Logs to
  /// another's is one tap. It moves only when it has to, off Overview, which
  /// is not a screen of any cluster, or off a screen this cluster does not
  /// have.
  void _select(ManagedCluster cluster, {Section? section}) {
    final engines = Engines.of(context);
    engines.store.selected = cluster.id;
    _folded = null;
    if (section != null) {
      engines.navigator.section = section;
    } else if (!engines.navigator.section.isAvailable(cluster)) {
      engines.navigator.section = Section.cluster;
    }
  }
}

/// The toolkit's icon for each screen, chosen here and not in the engines.
IconData sectionIcon(Section section) => switch (section) {
      Section.overview => Icons.grid_view_rounded,
      Section.cluster => Icons.dns_outlined,
      Section.tmmLive => Icons.monitor_heart_outlined,
      Section.resources => Icons.list_alt_outlined,
      Section.logs => Icons.notes_outlined,
      Section.dpu => Icons.hub_outlined,
      Section.nico => Icons.lan_outlined,
      Section.kubevirt => Icons.computer_outlined,
      Section.terminal => Icons.terminal_outlined,
    };

/// One screen in the outline: Overview at the top, or a cluster's screen under it.
class SectionRow extends StatelessWidget {
  final Section section;
  final bool active;
  final bool indented;
  final VoidCallback onTap;
  const SectionRow({super.key, required this.section, required this.active, this.indented = false, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = active ? Tokens.activeFg : Tokens.fg;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: indented ? 32 : 38,
        margin: const EdgeInsets.only(bottom: 2),
        padding: EdgeInsets.only(left: indented ? 26 : 11, right: 11),
        decoration: BoxDecoration(
          color: active ? Tokens.primary.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          SizedBox(width: 18, child: Icon(sectionIcon(section), size: indented ? 15 : 17, color: color)),
          const SizedBox(width: 11),
          Expanded(
            child: Text(section.title,
                style: Tokens.text(indented ? 13 : 14, weight: active ? FontWeight.w600 : FontWeight.w500, color: color),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
        ]),
      ),
    );
  }
}

/// A cluster and, when it is the selected one, the screens it has.
class _ClusterGroup extends StatelessWidget {
  final ManagedCluster cluster;
  final bool selected;
  final bool expanded;
  final Section active;
  final VoidCallback onHeader;
  final void Function(Section) onOpen;
  const _ClusterGroup(
      {required this.cluster,
      required this.selected,
      required this.expanded,
      required this.active,
      required this.onHeader,
      required this.onOpen});

  @override
  Widget build(BuildContext context) => Observe([cluster], builder: (context) {
        return Column(children: [
          // Selectable even when unusable: the row cannot open a cluster the
          // app cannot talk to, but it can open the screen that says why and
          // has the Remove button.
          InkWell(
            onTap: onHeader,
            borderRadius: BorderRadius.circular(8),
            child: ClusterRow(cluster: cluster, selected: selected, expanded: expanded),
          ),
          if (expanded)
            for (final item in Section.available(cluster))
              SectionRow(section: item, active: active == item, indented: true, onTap: () => onOpen(item)),
        ]);
      });
}

class ClusterRow extends StatelessWidget {
  final ManagedCluster cluster;
  final bool selected;
  final bool expanded;
  const ClusterRow({super.key, required this.cluster, required this.selected, required this.expanded});

  @override
  Widget build(BuildContext context) {
    final reach = cluster.reach;
    final reachable = reach is Reachable;
    final dot = switch (reach) {
      Reachable() => Tokens.ok,
      Unprobed() => Tokens.muted,
      Unreachable() || Unusable() => Tokens.deadDot,
    };
    // One line, and a short one: the sentence that says why lives on the
    // Cluster screen, where there is room to read it.
    final subtitle = switch (reach) {
      Reachable(:final version) => '${cluster.context.server.host} · $version',
      Unprobed() => cluster.context.server.host,
      Unreachable() => 'no route',
      Unusable() => 'credentials this app cannot use',
    };
    final roles = cluster.roles.toList()..sort((a, b) => a.label.compareTo(b.label));
    final edition = cluster.k0rdent.edition;
    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
      decoration: BoxDecoration(
        color: selected ? Tokens.secondary : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: selected ? Tokens.border : Colors.transparent),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          // The disclosure is drawn, not pressed: the whole row is the
          // button, and a second tap on the selected row is what folds it.
          SizedBox(
            width: 10,
            child: AnimatedRotation(
              turns: expanded ? 0.25 : 0,
              duration: const Duration(milliseconds: 150),
              child: const Icon(Icons.chevron_right, size: 12, color: Tokens.faint),
            ),
          ),
          const SizedBox(width: 8),
          StatusDot(color: dot, glow: reachable),
          const SizedBox(width: 8),
          Expanded(
            child: Text(cluster.displayName,
                style: Tokens.text(13, weight: FontWeight.w600, color: reachable ? Tokens.fg : Tokens.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
        ]),
        const SizedBox(height: 5),
        Padding(
          padding: const EdgeInsets.only(left: 33),
          child: Text(subtitle,
              style: Tokens.mono(10.5, color: reachable ? Tokens.muted : Tokens.faint), maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        if (roles.isNotEmpty) ...[
          const SizedBox(height: 5),
          Padding(
            padding: const EdgeInsets.only(left: 33),
            // Badges laid out left to right, and onto a new line when the
            // row is full: wrapping the whole badge is what a row of tags is
            // expected to do.
            child: Wrap(spacing: 5, runSpacing: 5, children: [
              for (final role in roles) Tag(role.label),
              // Which k0rdent, alongside the fact of it. The distinction
              // decides whether half the catalog is even available.
              if (edition != null && cluster.k0rdent.role == K0rdentRole.management)
                Tag(edition == K0rdentEdition.enterprise ? 'Enterprise' : 'Community',
                    tone: edition == K0rdentEdition.enterprise ? Tokens.ember : Tokens.muted),
            ]),
          ),
        ],
      ]),
    );
  }
}
