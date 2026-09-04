import 'package:bnk_engines/bnk_engines.dart';
import 'package:flutter/widgets.dart';

/// Every engine the app holds, one of each, reachable from any widget.
class Engines {
  final ClusterStore store;
  final TelemetryEngine telemetry;
  final LogsEngine logs;
  final ExecEngine exec;
  final NicoEngine nico;
  final OverviewEngine overview;
  final DpuEngine dpu;
  final KubeVirtEngine kubevirt;
  final ResourceEngine resources;
  final ScreenNavigator navigator;

  Engines({
    required this.store,
    TelemetryEngine? telemetry,
    LogsEngine? logs,
    ExecEngine? exec,
    NicoEngine? nico,
    OverviewEngine? overview,
    DpuEngine? dpu,
    KubeVirtEngine? kubevirt,
    ResourceEngine? resources,
    ScreenNavigator? navigator,
  })  : telemetry = telemetry ?? TelemetryEngine(),
        logs = logs ?? LogsEngine(),
        exec = exec ?? ExecEngine(),
        nico = nico ?? NicoEngine(),
        overview = overview ?? OverviewEngine(),
        dpu = dpu ?? DpuEngine(),
        kubevirt = kubevirt ?? KubeVirtEngine(),
        resources = resources ?? ResourceEngine(),
        navigator = navigator ?? ScreenNavigator();

  static Engines of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<EngineScope>()!.engines;

  void dispose() {
    telemetry.dispose();
    logs.dispose();
    exec.dispose();
    nico.dispose();
    overview.dispose();
    dpu.dispose();
    kubevirt.dispose();
    resources.dispose();
    navigator.dispose();
    store.dispose();
  }
}

class EngineScope extends InheritedWidget {
  final Engines engines;
  const EngineScope({super.key, required this.engines, required super.child});

  @override
  bool updateShouldNotify(EngineScope old) => !identical(old.engines, engines);
}
