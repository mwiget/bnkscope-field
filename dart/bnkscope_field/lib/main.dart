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
  unawaited(store.load().then((_) => store.probeAll()));
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
