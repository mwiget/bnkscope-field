import 'dart:io';

import 'package:bnk_engines/bnk_engines.dart';
import 'package:bnk_kit/testing.dart';
import 'package:bnkscope_field/engines.dart';
import 'package:bnkscope_field/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Resources and Logs against the fake apiserver.
void main() {
  const fixtures = Fixtures('../bnk_kit/test/fixtures');
  late FakeApiserver api;
  late Directory dir;

  setUpAll(() async {
    HttpOverrides.global = null;
    api = FakeApiserver(fixtures: fixtures);
    await api.start();
    dir = await Directory.systemTemp.createTemp('bnk-browse-');
  });

  tearDownAll(() async {
    await api.stop();
    await dir.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester, bool Function() ready, {int rounds = 60}) async {
    var n = 0;
    while (!ready()) {
      if (++n > rounds) fail('not ready after $n rounds');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    await tester.pump();
  }

  testWidgets('resources list nodes, then pods with their summaries, and open one', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    final store = ClusterStore(directory: dir);
    final engines = Engines(store: store);
    await tester.runAsync(() async {
      await store.importKubeconfig(fixtures.kubeconfig(api));
      await store.probeAll();
    });
    engines.navigator.section = Section.resources;
    await tester.pumpWidget(FieldApp(engines: engines));
    await settle(tester, () => engines.resources.objects.isNotEmpty);
    expect(find.text('Nodes'), findsOneWidget);
    expect(find.text('n1'), findsOneWidget);
    expect(find.text('NotReady · ? · '), findsOneWidget);

    // Overview's "open this pod" lands here with the pod open.
    engines.navigator.revealPod('broken', namespace: 'ns');
    await settle(tester, () => engines.navigator.pending == null && engines.resources.kind.plural == 'pods');
    await settle(tester, () => find.text('YAML').evaluate().isNotEmpty);
    expect(find.text('broken'), findsWidgets);
    expect(find.text('Pods · ns'), findsOneWidget);
    await settle(tester, () => engines.resources.events.isNotEmpty);
    expect(find.text('BackOff'), findsOneWidget);
    await tester.tap(find.text('YAML'));
    await tester.pump();
    expect(find.textContaining('phase: Pending'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pump();
    expect(find.text('0/1 ready · Pending · 7 restarts · n1'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    engines.dispose();
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('logs follow the TMM namespace and filter by level', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    final store = ClusterStore(directory: dir);
    final engines = Engines(store: store);
    await tester.runAsync(() async {
      await store.load();
      await store.probeAll();
    });
    engines.navigator.section = Section.logs;
    await tester.pumpWidget(FieldApp(engines: engines));
    // Three pods in ns, five containers, three lines each.
    await settle(tester, () => engines.logs.lines.length == 15);
    expect(find.text('TAILING'), findsOneWidget);
    expect(find.text('5 containers'), findsOneWidget);
    expect(find.textContaining('second line'), findsNWidgets(5));
    await tester.tap(find.text('error'));
    await tester.pump();
    expect(find.textContaining('second line'), findsNothing);
    expect(find.text('10 of 15'), findsOneWidget);

    engines.logs.stop();
    await tester.pumpWidget(const SizedBox());
    engines.dispose();
    await tester.pump(const Duration(seconds: 30));
  });
}
