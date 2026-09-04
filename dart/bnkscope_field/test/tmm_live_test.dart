import 'dart:io';

import 'package:bnk_engines/bnk_engines.dart';
import 'package:bnk_kit/testing.dart';
import 'package:bnkscope_field/engines.dart';
import 'package:bnkscope_field/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// TMM Live against the fake apiserver: the engine scrapes both pods over
/// real tunnels and the screen shows the pill, the tiles, the panels and
/// the targets. The test binding replaces HttpClient with one that answers
/// 400, so that override is lifted for this file.
void main() {
  const fixtures = Fixtures('../bnk_kit/test/fixtures');
  late FakeApiserver api;
  late Directory dir;

  setUpAll(() async {
    HttpOverrides.global = null;
    api = FakeApiserver(fixtures: fixtures);
    await api.start();
    dir = await Directory.systemTemp.createTemp('bnk-live-');
  });

  tearDownAll(() async {
    await api.stop();
    await dir.delete(recursive: true);
  });

  testWidgets('scrapes both TMM pods and draws the panels', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    final store = ClusterStore(directory: dir);
    final engines = Engines(store: store, telemetry: TelemetryEngine(liveInterval: const Duration(milliseconds: 300)));
    await tester.runAsync(() async {
      await store.importKubeconfig(fixtures.kubeconfig(api));
      await store.probeAll();
    });
    engines.navigator.section = Section.tmmLive;
    await tester.pumpWidget(FieldApp(engines: engines));
    await tester.pump();

    // Rates need two rounds. The loop's sleep is a timer in the fake-async
    // zone, so fake time is advanced between waits for the real sockets.
    var rounds = 0;
    while (engines.telemetry.panels[PanelId.throughput] == null || engines.telemetry.lastScrape == null) {
      if (++rounds > 60) fail('no throughput panel after $rounds rounds: ${engines.telemetry.state}');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    }
    await tester.pump();
    expect(find.text('LIVE'), findsOneWidget);

    expect(find.text('TMM PODS'), findsOneWidget);
    expect(find.text('2'), findsWidgets);
    expect(find.text(PanelId.connections.title), findsOneWidget);
    expect(find.text(PanelId.throughput.title), findsOneWidget);
    expect(find.text('Exporter targets'), findsOneWidget);
    expect(find.text('tmm-a'), findsOneWidget);
    expect(find.text('ephemeral'), findsNWidgets(2));
    expect(find.text('Direct'), findsOneWidget);

    // Zoom in on a panel and back out with Escape.
    await tester.tap(find.byTooltip('Expand ${PanelId.connections.title}'));
    // The card's double-tap recognizer holds a single tap until it is sure.
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('TMM PODS'), findsNothing);
    expect(find.byTooltip('Collapse ${PanelId.connections.title}'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('TMM PODS'), findsOneWidget);

    // Tear the screen down so its roster timer is cancelled with it.
    engines.telemetry.stop();
    await tester.pumpWidget(const SizedBox());
    engines.dispose();
    // Whatever keep-alive the pool still holds is let go with the client;
    // anything else in the fake zone is given time to fire.
    await tester.pump(const Duration(seconds: 30));
  });
}
