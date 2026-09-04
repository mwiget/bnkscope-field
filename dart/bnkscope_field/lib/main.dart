import 'dart:async';
import 'dart:io';

import 'package:bnk_engines/bnk_engines.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'engines.dart';
import 'platform.dart';
import 'root.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await sizeDesktopWindow();
  // Kubeconfigs live in application support, one file per context. Real
  // cluster credentials: the app's own sandbox, and nowhere shared.
  final support = await getApplicationSupportDirectory();
  final store = ClusterStore(directory: Directory('${support.path}/kubeconfigs'), words: deviceWords);
  final engines = Engines(store: store);
  // Load what was imported before, then ask every cluster what it is. Not
  // awaited: the window opens on the last known state and fills in.
  unawaited(store.load().then((_) async {
    openWhereAsked(engines);
    await store.probeAll();
    // Again, now that probing has said which screens the cluster has: a
    // screen asked for before the roles were known was sent back to Cluster.
    openWhereAsked(engines);
  }));
  runApp(FieldApp(engines: engines));
}

class FieldApp extends StatefulWidget {
  final Engines engines;
  const FieldApp({super.key, required this.engines});

  @override
  State<FieldApp> createState() => _FieldAppState();
}

class _FieldAppState extends State<FieldApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The tablet sleeping, or the app being swiped away, must stop the
  /// scrape loop; otherwise it keeps a tunnel open into a live TMM pod for a
  /// session nobody is watching. Losing focus is not that: on a desktop a
  /// window goes inactive every time another is clicked, and pausing there
  /// would put a break in every chart for no reason.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final e = widget.engines;
    switch (state) {
      case AppLifecycleState.resumed:
        e.telemetry.resume();
      case AppLifecycleState.paused || AppLifecycleState.hidden || AppLifecycleState.detached:
        e.telemetry.pause();
        e.logs.stop();
        e.exec.cancel();
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  Widget build(BuildContext context) => EngineScope(
        engines: widget.engines,
        child: MaterialApp(
          title: 'bnkscope Field',
          theme: Tokens.theme,
          debugShowCheckedModeBanner: false,
          home: const RootView(),
        ),
      );
}

/// Open on a given screen and cluster when the environment asks, so a
/// screenshot or a demo can start where it needs to without a tap. Names
/// are the Section enum's and the cluster's display name; anything that
/// does not match is ignored.
///
///     BNK_SECTION=tmmLive BNK_CLUSTER=dpu-cplane-tenant1 "bnkscope Field.app/Contents/MacOS/bnkscope Field"
void openWhereAsked(Engines engines) {
  final env = Platform.environment;
  final wanted = env['BNK_CLUSTER'];
  if (wanted != null) {
    for (final c in engines.store.clusters) {
      if (c.displayName == wanted || c.id == wanted) engines.store.selected = c.id;
    }
  }
  final section = env['BNK_SECTION'];
  if (section != null) {
    for (final s in Section.values) {
      if (s.name == section) engines.navigator.section = s;
    }
  }
}
