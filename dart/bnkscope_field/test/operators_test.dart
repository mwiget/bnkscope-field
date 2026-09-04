import 'dart:io';

import 'package:bnk_engines/bnk_engines.dart';
import 'package:bnk_kit/testing.dart';
import 'package:bnkscope_field/engines.dart';
import 'package:bnkscope_field/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// DPU, KubeVirt, NICo and Terminal against the fake apiserver, with the
/// operator APIs added as routes.
void main() {
  const fixtures = Fixtures('../bnk_kit/test/fixtures');
  late FakeApiserver api;
  late Directory dir;

  setUpAll(() async {
    HttpOverrides.global = null;
    api = FakeApiserver(fixtures: fixtures);
    api.routes['/apis'] = (_) => {
          'groups': [
            {'name': 'apps', 'preferredVersion': {'groupVersion': 'apps/v1'}},
            {'name': 'kubevirt.io', 'preferredVersion': {'groupVersion': 'kubevirt.io/v1'}},
          ]
        };
    api.routes['/apis/svc.dpu.nvidia.com/v1alpha1/servicechains'] = (_) => {
          'items': [
            {
              'metadata': {'name': 'hbn-1', 'namespace': 'dpf'},
              'spec': {
                'node': 'dpu-node-1',
                'switches': [
                  {'serviceMTU': 1500, 'ports': [
                    {'serviceInterface': {'matchLabels': {'interface': 'p0'}}},
                    {'serviceInterface': {'matchLabels': {'svc.dpu.nvidia.com/interface': 'p0_if', 'svc.dpu.nvidia.com/service': 'hbn'}}},
                  ]},
                ],
              },
              'status': {'conditions': [{'type': 'Ready', 'status': 'True'}]},
            }
          ]
        };
    api.routes['/apis/svc.dpu.nvidia.com/v1alpha1/serviceinterfaces'] = (_) => {
          'items': [
            {'metadata': {'name': 'p0', 'namespace': 'dpf'}, 'spec': {'interfaceType': 'physical', 'node': 'dpu-node-1', 'physical': {'interfaceName': 'p0'}},
              'status': {'conditions': [{'type': 'Ready', 'status': 'True'}]}},
            {'metadata': {'name': 'hbn-p0', 'namespace': 'dpf'}, 'spec': {'interfaceType': 'service', 'node': 'dpu-node-1',
              'service': {'interfaceName': 'p0_if', 'network': 'mybr', 'serviceID': 'hbn'}},
              'status': {'conditions': [{'type': 'Ready', 'status': 'False'}]}},
          ]
        };
    api.routes['/apis/kubevirt.io/v1/virtualmachines'] = (_) => {
          'items': [
            {'metadata': {'name': 'halted', 'namespace': 'default'}, 'spec': {'runStrategy': 'Halted',
              'template': {'spec': {'domain': {'devices': {'disks': [{'name': 'root', 'disk': {'bus': 'virtio'}}]}},
                'volumes': [{'name': 'root', 'containerDisk': {'image': 'quay.io/x/fedora'}}]}}},
              'status': {'printableStatus': 'Stopped'}},
          ]
        };
    api.routes['/apis/kubevirt.io/v1/virtualmachineinstances'] = (_) => {
          'items': [
            {'metadata': {'name': 'lone', 'namespace': 'default'},
              'spec': {'domain': {'cpu': {'cores': 2}, 'memory': {'guest': '4Gi'}, 'devices': {'interfaces': [{'name': 'default', 'masquerade': {}}]}},
                'networks': [{'name': 'default', 'pod': {}}]},
              'status': {'phase': 'Running', 'nodeName': 'n1', 'interfaces': [{'name': 'default', 'ipAddress': '10.0.0.5', 'linkState': 'up'}]}},
          ]
        };
    api.routes['/apis/k8s.cni.cncf.io/v1/network-attachment-definitions'] = (_) => {'items': []};
    await api.start();
    dir = await Directory.systemTemp.createTemp('bnk-ops-');
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

  Future<Engines> boot(WidgetTester tester, Section section) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    final store = ClusterStore(directory: dir);
    final engines = Engines(store: store);
    await tester.runAsync(() async {
      await store.load();
      if (store.clusters.isEmpty) await store.importKubeconfig(fixtures.kubeconfig(api));
      await store.probeAll();
    });
    engines.navigator.section = section;
    await tester.pumpWidget(FieldApp(engines: engines));
    return engines;
  }

  Future<void> shutdown(WidgetTester tester, Engines engines) async {
    await tester.pumpWidget(const SizedBox());
    engines.dispose();
    await tester.pump(const Duration(seconds: 30));
  }

  testWidgets('DPU shows the chains as joined ports and the interfaces by kind', (tester) async {
    final engines = await boot(tester, Section.dpu);
    expect(engines.store.current!.roles, contains(ClusterRole.dpu));
    await settle(tester, () => engines.dpu.chains.isNotEmpty && !engines.dpu.loading);
    expect(find.text('1/1 ready'), findsOneWidget);
    expect(find.text('1/2 ready'), findsOneWidget);
    expect(find.text('hbn-1'), findsOneWidget);
    expect(find.text('p0_if · hbn'), findsOneWidget);
    expect(find.text('mtu 1500'), findsOneWidget);
    expect(find.text('physical'), findsOneWidget);
    await shutdown(tester, engines);
  });

  testWidgets('KubeVirt lists a stopped machine with Start and a standalone instance without', (tester) async {
    final engines = await boot(tester, Section.kubevirt);
    expect(engines.store.current!.roles, contains(ClusterRole.kubevirt));
    await settle(tester, () => engines.kubevirt.machines.length == 2);
    expect(find.text('1/2 running'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('standalone VMI'), findsOneWidget);
    expect(find.textContaining('boot from a containerDisk'), findsOneWidget);
    expect(find.text('ephemeral'), findsOneWidget);
    expect(find.text('10.0.0.5'), findsOneWidget);
    await shutdown(tester, engines);
  });

  testWidgets('Terminal runs a diagnostic in the debug container and keeps its output', (tester) async {
    final engines = await boot(tester, Section.terminal);
    await settle(tester, () => find.text('Run').evaluate().isNotEmpty);
    expect(find.text('main'), findsWidgets, reason: 'the only container in the fake pod is the tool container');
    expect(find.text('cpu'), findsOneWidget);
    await tester.tap(find.text('cpu'));
    await tester.pump();
    await settle(tester, () => engines.exec.runs.isNotEmpty && engines.exec.runs.last.finished);
    expect(find.textContaining('ran: tmctl -d blade tmm_stat'), findsOneWidget);
    expect(find.textContaining('a warning'), findsOneWidget);
    // The last command is offered back as the completion of an empty line.
    expect(find.text('tab ⇥'), findsOneWidget);
    await shutdown(tester, engines);
  });

  testWidgets('NICo says why it has nothing when the cluster does not run it', (tester) async {
    final engines = await boot(tester, Section.nico);
    // Not available on this cluster, so the root sends the screen to Cluster.
    await tester.pump();
    expect(engines.navigator.section, Section.cluster);
    await shutdown(tester, engines);
  });
}
