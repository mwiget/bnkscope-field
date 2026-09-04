import 'dart:io';

import 'package:bnk_engines/bnk_engines.dart';
import 'package:bnkscope_field/engines.dart';
import 'package:bnkscope_field/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bnk-app-');
  });

  tearDown(() => dir.delete(recursive: true));

  testWidgets('an empty store offers the import on Overview', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    final engines = Engines(store: ClusterStore(directory: dir));
    await tester.pumpWidget(FieldApp(engines: engines));
    await tester.pumpAndSettle();
    expect(find.text('No clusters yet'), findsOneWidget);
    expect(find.text('Import kubeconfig'), findsNWidgets(2), reason: 'sidebar and the empty state');
    expect(find.text('Overview'), findsWidgets);
    engines.dispose();
  });

  testWidgets('a dead cluster shows in the sidebar and the overview says it is unreachable', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    final store = ClusterStore(directory: dir);
    final engines = Engines(store: store);
    await tester.runAsync(() async {
      await store.importKubeconfig('''
clusters: [{name: dead, cluster: {server: "https://127.0.0.1:1", insecure-skip-tls-verify: true}}]
contexts: [{name: admin@dead, context: {cluster: dead, user: u}}]
users: [{name: u, user: {token: t}}]
''');
      await store.probeAll();
    });
    await tester.pumpWidget(FieldApp(engines: engines));
    await tester.pumpAndSettle();
    expect(find.text('dead'), findsWidgets);
    expect(find.text('no route'), findsOneWidget);
    expect(find.text('Unreachable'), findsOneWidget);

    // Open lands on the Cluster screen, which says why.
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('CONTEXT'), findsOneWidget);
    expect(find.text('admin@dead'), findsOneWidget);
    // The test binding replaces HttpClient, so the reason is whatever the
    // probe was told; the screen must show it, whatever it was.
    final why = (store.clusters.single.reach as Unreachable).why;
    expect(find.text(why), findsOneWidget);

    // A narrow window folds the sidebar into a drawer that the toggle opens.
    tester.view.physicalSize = const Size(600, 800);
    await tester.pumpAndSettle();
    expect(find.text('Probe all'), findsNothing);
    await tester.tap(find.byTooltip('Show clusters'));
    await tester.pumpAndSettle();
    expect(find.text('Probe all'), findsOneWidget);
    engines.dispose();
  });
}
