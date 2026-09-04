import 'dart:convert';
import 'dart:io';

import 'package:bnk_engines/bnk_engines.dart';
import 'package:bnk_kit/bnk_kit.dart';
import 'package:test/test.dart';

KubeContext ctx(String name, String cluster, String server, {KubeAuth auth = const BearerTokenAuth('t')}) =>
    KubeContext(name: name, clusterName: cluster, server: Uri.parse(server), caPEM: null,
        tlsServerName: null, insecureSkipTLSVerify: false, namespace: null, auth: auth);

void main() {
  group('ManagedCluster', () {
    test('shows the cluster, not kubectl\'s user@cluster', () {
      expect(ManagedCluster(context: ctx('kubernetes-admin@dpu-cplane-tenant1', 'dpu-cplane-tenant1', 'https://h:1'), sourceFile: 'f').displayName,
          'dpu-cplane-tenant1');
      // A kubeadm cluster is called "kubernetes" on every install; the address is what tells two apart.
      expect(ManagedCluster(context: ctx('kubernetes-admin@kubernetes', 'kubernetes', 'https://192.168.68.83:6443'), sourceFile: 'f').displayName,
          '192.168.68.83:6443');
      expect(ManagedCluster(context: ctx('bnk232', 'bnk232', 'https://h'), sourceFile: 'f').displayName, 'bnk232');
    });

    test('an exec context is unusable from the start', () {
      final c = ManagedCluster(context: ctx('eks', 'eks', 'https://h', auth: const UnsupportedAuth('needs aws')), sourceFile: 'f');
      expect(c.isUsable, isFalse);
      expect(c.reach, isA<Unusable>());
      expect(Section.available(c), [Section.cluster]);
    });

    test('explains socket and TLS failures in the reader\'s terms', () {
      const words = DeviceWords(thisDevice: 'this iPad', localNetworkSetting: 'Settings › Privacy', importSource: 'from Files');
      expect(ManagedCluster.explain(const UnusableFailure('needs aws')), 'needs aws');
      expect(ManagedCluster.explain(const HandshakeException('bad'), words: words), contains('TLS handshake'));
      expect(
          ManagedCluster.explain(
              SocketException('x', osError: const OSError('Connection refused', 61), address: InternetAddress('192.168.1.5')),
              words: words),
          'no route to this address from this iPad');
      expect(
          ManagedCluster.explain(
              SocketException('x', osError: const OSError('Operation not permitted', 1), address: InternetAddress('192.168.1.5')),
              words: words),
          contains('Settings › Privacy'));
      expect(
          ManagedCluster.explain(
              SocketException('x', osError: const OSError('No route to host', 65), address: InternetAddress('192.168.1.5')),
              words: words),
          allOf(contains('no route to this local address'), contains('Settings › Privacy')));
      expect(
          ManagedCluster.explain(
              SocketException('x', osError: const OSError('No route to host', 113), address: InternetAddress('8.8.8.8')),
              words: words),
          'no route to this address from this iPad');
      expect(ManagedCluster.explain(Exception('odd')), 'Exception: odd');
    });
  });

  group('ClusterStore', () {
    test('file names are one cluster\'s and safe on disk', () {
      expect(ClusterStore.filenameFor('kubernetes-admin@kubernetes'), 'kubernetes-admin-kubernetes.kubeconfig');
      expect(ClusterStore.filenameFor('a/b c.d'), 'a-b-c.d.kubeconfig');
    });
  });

  group('Sections', () {
    test('nico, dpu and kubevirt appear only where they run', () {
      final c = ManagedCluster(context: ctx('c', 'c', 'https://h'), sourceFile: 'f');
      expect(Section.available(c), isNot(contains(Section.nico)));
      expect(Section.available(c), isNot(contains(Section.overview)));
      expect(Section.available(c).first, Section.cluster);
    });

    test('the navigator carries a reveal request until it is acted on', () {
      final n = ScreenNavigator();
      var changes = 0;
      n.changes.listen((_) => changes++);
      n.revealPod('broken', namespace: 'ns');
      expect(n.section, Section.resources);
      expect(n.pending, const RevealRequest(kind: 'pods', namespace: 'ns', name: 'broken'));
      n.clear();
      expect(n.pending, isNull);
      expect(changes, 2);
    });
  });

  group('Overview', () {
    test('headlines count what is wrong', () {
      expect(OverviewEngine.headline(Severity.healthy, 0), 'Nothing wrong');
      expect(OverviewEngine.headline(Severity.warning, 1), '1 thing worth a look');
      expect(OverviewEngine.headline(Severity.critical, 3), '3 things wrong');
    });

    test('strips the preamble Kubernetes puts on repeated events', () {
      expect(OverviewEngine.tidy('(combined from similar events): Back-off restarting'), 'Back-off restarting');
      expect(OverviewEngine.tidy('x' * 200).length, 161);
    });
  });

  group('Telemetry', () {
    test('panel data keeps order by name and records breaks', () {
      final p = PanelData();
      final t0 = DateTime.utc(2026, 9, 4, 12);
      p.append({'b': 1, 'a': 2}, t0, 900);
      p.append({'a': 3}, t0.add(const Duration(seconds: 2)), 900);
      expect(p.names, ['a', 'b']);
      p.breakLines(t0.add(const Duration(seconds: 4)), 900);
      expect(p.lines['a']!.last.v, isNull);
      expect(p.latest('a'), 3);
      expect(p.latest('b'), 1);
      // A second break on an already broken line adds nothing.
      p.breakLines(t0.add(const Duration(seconds: 6)), 900);
      expect(p.lines['a']!.length, 3);
    });

    test('trims to the history limit', () {
      final p = PanelData();
      for (var i = 0; i < 10; i++) {
        p.append({'a': i.toDouble()}, DateTime.utc(2026, 1, 1, 0, 0, i), 4);
      }
      expect(p.lines['a']!.map((pt) => pt.v), [6, 7, 8, 9]);
    });

    test('formats values the way the panels label them', () {
      expect(ValueFormat.percent(97.25), '97.3%');
      expect(ValueFormat.count(12.7), '13');
      expect(ValueFormat.perSecond(3.14159), '3.1/s');
      expect(ValueFormat.perSecond(250), '250/s');
      expect(ValueFormat.bitsPerSecond(950), '950 b/s');
      expect(ValueFormat.bitsPerSecond(1500000), '1.50 Mb/s');
      expect(PanelId.cpu.yDomain, (min: 0, max: 100));
      expect(PanelId.throughput.yDomain, isNull);
      expect(PanelId.cpu.format, ValueFormat.percent);
    });

    test('tenants are read off the virtual-server names', () {
      final samples = [
        const Sample('f5tmm_virtual_server_clientside_tot_conns', {'name': 'tenant-acme-http-vs'}, 5),
        const Sample('f5tmm_virtual_server_clientside_tot_conns', {'name': 'tenant-acme-tcp-vs'}, 5),
        const Sample('f5tmm_virtual_server_clientside_tot_conns', {'name': 'tenant-beta-http-vs'}, 5),
        const Sample('f5tmm_virtual_server_clientside_tot_conns', {'name': 'scn-other-vs'}, 5),
      ];
      final keys = TelemetryEngine.tenantKeys(samples, 'f5tmm_virtual_server_clientside_tot_conns');
      expect(keys.keys.toSet(), {'acme', 'beta'});
      expect(keys['acme']!.length, 2);
      expect(TelemetryEngine.sum(samples, 'f5tmm_virtual_server_clientside_tot_conns'), 20);
      expect(TelemetryEngine.total(samples, (s) => s.name).length, 1);
      expect(shortPodName('dpu-cplane-tenant1-tmm-g6lx4-f5-tmm-dhm72'), 'dhm72');
    });
  });

  group('Exec', () {
    test('joins a line split across chunks and fills the cursor line', () {
      final lines = <ExecLine>[];
      ExecEngine.appendChunk(lines, 'row 1 col', isError: false);
      ExecEngine.appendChunk(lines, 'umn\nrow 2\n', isError: false);
      ExecEngine.appendChunk(lines, 'row 3\n', isError: false);
      ExecEngine.appendChunk(lines, 'warn\n', isError: true);
      ExecEngine.appendChunk(lines, 'a\n\nb', isError: false);
      expect(lines.map((l) => l.text), ['row 1 column', 'row 2', 'row 3', 'warn', 'a', '', 'b']);
      expect(lines[3].isError, isTrue);
      expect(lines[4].isError, isFalse);
    });
  });

  group('Resource summaries', () {
    RawObject obj(String s) => RawObject.tryFrom(Map<String, dynamic>.from(jsonDecode(s) as Map))!;
    ResourceKind kind(String plural) => ResourceKind.all.firstWhere((k) => k.plural == plural);

    test('a pod says its readiness, restarts and node', () {
      final o = obj('{"metadata":{"name":"p"},"spec":{"nodeName":"n1"},"status":{"phase":"Running",'
          '"containerStatuses":[{"ready":true,"restartCount":3},{"ready":false,"restartCount":0}]}}');
      final line = ResourceSummary.line(o, kind('pods'));
      expect(line.text, '1/2 ready · Running · 3 restarts · n1');
      expect(line.tone, SummaryTone.bad);
    });

    test('a node says whether it is ready', () {
      final o = obj('{"metadata":{"name":"n"},"status":{"conditions":[{"type":"Ready","status":"True"}],'
          '"nodeInfo":{"kubeletVersion":"v1.33.13","architecture":"amd64"}}}');
      expect(ResourceSummary.line(o, kind('nodes')), (text: 'Ready · v1.33.13 · amd64', tone: SummaryTone.good));
    });

    test('a service says its address and ports', () {
      final o = obj('{"metadata":{"name":"s"},"spec":{"type":"NodePort","clusterIP":"10.0.0.1","ports":[{"port":80},{"port":443}]}}');
      expect(ResourceSummary.line(o, kind('services')).text, 'NodePort · 10.0.0.1 · 80,443');
    });
  });

  group('NICo', () {
    test('matches a tenant endpoint to a held cluster by host and port', () {
      final held = [
        ManagedCluster(context: ctx('kubernetes-admin@dpu-cplane-tenant1', 'dpu-cplane-tenant1', 'https://192.168.68.200:32170'), sourceFile: 'f'),
        ManagedCluster(context: ctx('other', 'other', 'https://h'), sourceFile: 'f'),
      ];
      expect(NicoEngine.match('192.168.68.200:32170', held), 'dpu-cplane-tenant1');
      expect(NicoEngine.match('h:443', held), isNull);
    });

    test('headline totals only the metrics that are present', () {
      final m = NicoEngine.headline([
        const Sample('nico_api_db_queries_total', {'op': 'a'}, 3),
        const Sample('nico_api_db_queries_total', {'op': 'b'}, 4),
      ]);
      expect(m, {'nico_api_db_queries_total': 7});
    });
  });
}
