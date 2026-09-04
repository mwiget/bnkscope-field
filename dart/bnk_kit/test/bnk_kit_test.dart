import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bnk_kit/bnk_kit.dart';
import 'package:test/test.dart';

JsonMap json(String s) => Map<String, dynamic>.from(jsonDecode(s) as Map);

void main() {
  group('Kubeconfig', () {
    test('parses a client certificate context', () {
      final cfg = Kubeconfig.parse('''
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: Y2E=
    server: https://203.0.113.20:32170
  name: dpu-cplane-tenant1
contexts:
- context:
    cluster: dpu-cplane-tenant1
    user: kubernetes-admin
    namespace: dpf-operator-system
  name: kubernetes-admin@dpu-cplane-tenant1
users:
- name: kubernetes-admin
  user:
    client-certificate-data: Y3J0
    client-key-data: a2V5
''');
      expect(cfg.contexts.length, 1);
      final c = cfg.context('kubernetes-admin@dpu-cplane-tenant1')!;
      expect(c.server.toString(), 'https://203.0.113.20:32170');
      expect(c.namespace, 'dpf-operator-system');
      expect(c.caPEM, utf8.encode('ca'));
      expect(
          c.auth,
          ClientCertificateAuth(Uint8List.fromList(utf8.encode('crt')),
              Uint8List.fromList(utf8.encode('key'))));
    });

    /// An `exec:` context must survive parsing and say why it cannot be used;
    /// dropping it would leave the user wondering where their cluster went.
    test('names the binary an exec context needs', () {
      final cfg = Kubeconfig.parse('''
clusters: [{name: eks, cluster: {server: https://example.invalid}}]
contexts: [{name: eks, context: {cluster: eks, user: eks}}]
users:
- name: eks
  user:
    exec:
      command: aws
      args: [eks, get-token]
''');
      final auth = cfg.contexts[0].auth;
      expect(auth, isA<UnsupportedAuth>());
      expect((auth as UnsupportedAuth).reason, contains('aws'));
    });

    test('reads bearer tokens', () {
      final cfg = Kubeconfig.parse('''
clusters: [{name: c, cluster: {server: https://example.invalid}}]
contexts: [{name: c, context: {cluster: c, user: u}}]
users: [{name: u, user: {token: abc123}}]
''');
      expect(cfg.contexts[0].auth, const BearerTokenAuth('abc123'));
    });

    test('rejects a context whose cluster is missing', () {
      expect(
          () => Kubeconfig.parse('''
clusters: []
contexts: [{name: c, context: {cluster: gone, user: u}}]
users: []
'''),
          throwsA(isA<KubeconfigException>()));
    });

    test('splits a file into one self-contained kubeconfig per context', () {
      const two = '''
apiVersion: v1
clusters:
- cluster: {server: "https://a.example:6443", certificate-authority-data: Y2E=}
  name: a
- cluster: {server: "https://b.example:6443", insecure-skip-tls-verify: true}
  name: b
contexts:
- context: {cluster: a, user: ua, namespace: kube-system}
  name: ctx-a
- context: {cluster: b, user: ub}
  name: ctx-b
users:
- name: ua
  user: {client-certificate-data: Y3J0, client-key-data: a2V5}
- name: ub
  user: {token: "t0ken: with colon"}
''';
      final parts = Kubeconfig.split(two);
      expect(parts.map((p) => p.name), ['ctx-a', 'ctx-b']);
      final a = Kubeconfig.parse(parts[0].yaml);
      expect(a.contexts.length, 1);
      expect(a.contexts[0].namespace, 'kube-system');
      expect(a.contexts[0].auth, isA<ClientCertificateAuth>());
      expect(a.contexts[0].caPEM, utf8.encode('ca'));
      final b = Kubeconfig.parse(parts[1].yaml);
      expect(b.contexts[0].insecureSkipTLSVerify, isTrue);
      expect(b.contexts[0].auth, const BearerTokenAuth('t0ken: with colon'));
      expect(parts[1].yaml, contains('current-context: ctx-b'));
    });
  });

  group('YAML emitter', () {
    test('writes block style that the parser reads back', () {
      final doc = {
        'name': 'x',
        'list': [1, 'two', {'k': 'v', 'n': null}, []],
        'nested': {'yes': 'yes', 'num': '10', 'real': 1.5, 'flag': true},
        'empty': {},
        'multi': 'a\nb',
        'space': 'has space',
      };
      final text = emitYaml(doc);
      // `n` is a YAML 1.1 boolean, so it is quoted as a key.
      expect(text, contains('- 1\n- two\n- k: v\n  "n": null\n- []\n'));
      expect(text, contains('"yes": "yes"'));
      expect(text, contains('num: "10"'));
      expect(text, contains('empty: {}'));
      expect(text, contains('space: "has space"'));
      // Through the same parser the package uses, and back to the same value.
      final back = Kubeconfig.parse('${text}contexts: [{name: c, context: {cluster: k}}]\nclusters: [{name: k, cluster: {server: https://h}}]\n');
      expect(back.contexts.length, 1);
    });
  });

  group('Exposition format', () {
    test('parses samples with and without labels', () {
      final samples = PromText.parse('''
# TYPE f5tmm_up gauge
f5tmm_up 1
# TYPE f5tmm_tmm_client_side_traffic_cur_conns gauge
f5tmm_tmm_client_side_traffic_cur_conns{pid="59",cpu="0",slot_id="0"} 11
f5tmm_scrape_duration_seconds 0.019739

''');
      expect(samples.length, 3);
      expect(samples[0], const Sample('f5tmm_up', {}, 1));
      expect(samples[1].labels['pid'], '59');
      expect(samples[1].seriesKey,
          'f5tmm_tmm_client_side_traffic_cur_conns{cpu=0,pid=59,slot_id=0}');
      expect(samples[2].value, 0.019739);
    });

    /// Label values are quoted and may contain the characters a naive split
    /// would treat as separators.
    test('parses label values containing separators', () {
      final s = PromText.parse(r'm{a="x,y",b="he said \"hi\"",c="1"} 5');
      expect(s.length, 1);
      expect(s[0].labels['a'], 'x,y');
      expect(s[0].labels['b'], 'he said "hi"');
      expect(s[0].labels['c'], '1');
    });

    test('reads the special float spellings', () {
      final s = PromText.parse('a NaN\nb +Inf\nc -Inf\n');
      expect(s[0].value.isNaN, isTrue);
      expect(s[1].value, double.infinity);
      expect(s[2].value, double.negativeInfinity);
    });

    test('skips comments and blank lines', () {
      expect(PromText.parse('# HELP x y\n\n   \n# TYPE x gauge\n'), isEmpty);
    });
  });

  group('Gzip', () {
    /// The fixture is a real `/metrics` body from the published exporter
    /// image, captured off the wire. If our inflater and the exporter's
    /// compressor ever disagree, this is where it shows.
    test('inflates a real scrape from the exporter', () {
      final compressed = File('test/fixtures/metrics.gz').readAsBytesSync();
      final text = Gzip.inflate(compressed);
      expect(compressed.length, lessThan(text.length ~/ 10),
          reason: 'the fixture should compress at least tenfold');
      final samples = PromText.parseBytes(text);
      expect(samples.length, greaterThan(500));
      expect(samples.any((s) => s.name == 'f5tmm_up' && s.value == 1), isTrue);
      expect(samples.every((s) => s.name.isNotEmpty), isTrue);
    });

    test('refuses a thing that is not gzip', () {
      expect(() => Gzip.inflate(List.filled(64, 0x41)),
          throwsA(isA<GzipException>()));
    });
  });

  group('HTTP reply', () {
    test('reads a gzipped reply\'s headers', () {
      final reply = HttpReply(
          status: 200,
          headers: const {'content-type': 'text/plain', 'content-encoding': 'gzip'},
          body: Uint8List.fromList(const [0x1f, 0x8b, 0x08]));
      expect(reply.status, 200);
      expect(reply.isGzipped, isTrue);
      expect(reply.headers['content-type'], 'text/plain');
    });

    test('does not claim gzip without the header', () {
      expect(
          HttpReply(status: 503, headers: const {}, body: Uint8List(0)).isGzipped,
          isFalse);
    });
  });

  group('Log levels', () {
    /// Every string here was taken off a real cluster, not invented. The
    /// first version of the heuristic scored all four of the error cases as
    /// `info`.
    test('classifies lines from a real cluster', () {
      const cases = <(String, LogLevel)>[
        ('{"ts"="2026-08-31 11:25:51.962"|"l"="error"|"m"="failed to create AMQP"}', LogLevel.error),
        ('{"ts"="2026-08-31 11:25:51.962"|"l"="critical"|"m"="failed to setup exchange"}', LogLevel.error),
        ('{"ts"="2026-08-31 11:25:51.903"|"l"="info"|"m"="exchange name"}', LogLevel.info),
        ('Aug 31 11:25:52.533248 tmm3[355] conn-sdb – Redis connection establishment with sentinel server failed', LogLevel.warning),
        ('Aug 31 11:25:51.336241 tmm6[453] conn-db – Trying redis connect with iteration = 119', LogLevel.info),
        ('I0831 07:38:30.447783   18857 custom_plugin_monitor.go:313] Initialized conditions', LogLevel.info),
        ('E0831 09:00:43.931896       1 controller.go:150] re-queuing item', LogLevel.error),
        ('W0831 09:00:43.931896       1 controller.go:150] slow response', LogLevel.warning),
        ('level=error msg="upstream refused"', LogLevel.error),
        ('{"level":"warn","msg":"retrying"}', LogLevel.warning),
        ('reconciled Gateway tenant1/edge-gw: 3 listeners, 12 routes attached', LogLevel.info),
      ];
      for (final (line, want) in cases) {
        expect(LogLevel.guessed(line), want, reason: '$want expected for: $line');
      }
    });

    /// The reassuring case a substring search turns into an alarm.
    test('does not raise an alarm over the absence of errors', () {
      expect(LogLevel.guessed('syncProxyRules took 18.4ms, 0 errors'), LogLevel.info);
      expect(LogLevel.guessed('health check complete, no errors'), LogLevel.info);
      expect(LogLevel.guessed('path /var/log/failed/ scanned'), LogLevel.info);
    });

    test('parses the timestamp Kubernetes prefixes', () {
      final line = LogLine.parse('2026-08-31T09:24:18.442839Z hello world', pod: 'p', container: 'c');
      expect(line.text, 'hello world');
      expect(line.at, isNotNull);
      expect(line.pod, 'p');
      expect(line.container, 'c');
    });

    test('accepts the nanosecond timestamps the kubelet writes', () {
      final line = LogLine.parse('2026-08-31T09:24:18.442839123Z x', pod: 'p');
      expect(line.at?.microsecond, 839);
      expect(line.text, 'x');
    });

    /// A line with no parseable timestamp keeps its whole text rather than
    /// losing the first word to a failed parse.
    test('keeps the whole line when there is no timestamp', () {
      final line = LogLine.parse('plain unprefixed output', pod: 'p');
      expect(line.text, 'plain unprefixed output');
      expect(line.at, isNull);
    });
  });

  group('F5 object names', () {
    test('the listening address is dropped, the identity kept', () {
      expect(F5Names.shortObjectName('scn-cwatch-scn-cwatch-gateway-203.0.113.105-http-80-vs'),
          'scn-cwatch-scn-cwatch-gateway');
      expect(F5Names.shortObjectName('scn-grpc-scn-grpc-l4-gateway-203.0.113.109-tcp-50052-vs'),
          'scn-grpc-scn-grpc-l4-gateway');
      expect(F5Names.shortObjectName('scn-udp-lb-scn-udp-lb-gateway-203.0.113.107-udp-5005-vs'),
          'scn-udp-lb-scn-udp-lb-gateway');
    });

    test('pool rules survive the trim', () {
      final a = F5Names.shortObjectName(
          'scn-aitok-dssm-aitok-llm-rag-gw-203.0.113.123-http-8000-aitok-llm-rag-route-rule-0-pool');
      final b = F5Names.shortObjectName(
          'scn-aitok-dssm-aitok-llm-code-gw-203.0.113.121-http-8000-aitok-llm-code-route-rule-0-pool');
      expect(a, 'scn-aitok-dssm-aitok-llm-rag-gw-aitok-llm-rag-route-rule-0');
      expect(a, isNot(b));
    });

    test('a name carrying no address is left alone', () {
      expect(F5Names.shortObjectName('tenant-acme-http-vs'), 'tenant-acme-http');
      expect(F5Names.shortObjectName('snat_automap[0]'), 'snat_automap[0]');
    });

    test('version-like runs are not addresses', () {
      expect(F5Names.looksLikeIPv4('999.1.1.1'), isFalse);
      expect(F5Names.looksLikeIPv4('1.2.3'), isFalse);
      expect(F5Names.looksLikeIPv4('203.0.113.105'), isTrue);
    });
  });

  group('Local addresses', () {
    test('the ranges a cluster in a lab actually sits on', () {
      expect(Net.isLocal('192.168.1.10'), isTrue);
      expect(Net.isLocal('10.0.0.1'), isTrue);
      expect(Net.isLocal('10.244.0.7'), isTrue);
      expect(Net.isLocal('172.17.0.1'), isTrue);
      expect(Net.isLocal('172.31.255.254'), isTrue);
    });

    test('names and loopback count as local', () {
      expect(Net.isLocal('localhost'), isTrue);
      expect(Net.isLocal('apiserver.local'), isTrue);
      expect(Net.isLocal('127.0.0.1'), isTrue);
      expect(Net.isLocal('169.254.1.1'), isTrue);
      expect(Net.isLocal('::1'), isTrue);
      expect(Net.isLocal('[fe80::1]'), isTrue);
    });

    test('routable addresses are not local', () {
      expect(Net.isLocal('8.8.8.8'), isFalse);
      expect(Net.isLocal('172.32.0.1'), isFalse);
      expect(Net.isLocal('172.15.0.1'), isFalse);
      expect(Net.isLocal('193.168.1.1'), isFalse);
      expect(Net.isLocal('api.example.com'), isFalse);
      expect(Net.isLocal('1.2.3'), isFalse);
      expect(Net.isLocal('999.1.1.1'), isFalse);
    });
  });

  group('Command lines', () {
    test('plain commands split on whitespace', () {
      expect(Argv.split('tmctl -d blade tmm_stat'), ['tmctl', '-d', 'blade', 'tmm_stat']);
      expect(Argv.split('  ip   -s  link  '), ['ip', '-s', 'link']);
      expect(Argv.split(''), <String>[]);
    });

    test('imish needs one argument to hold a whole ZebOS command', () {
      expect(Argv.split('imish -e en -e "show ip bgp summary"'),
          ['imish', '-e', 'en', '-e', 'show ip bgp summary']);
      expect(Argv.split("imish -e 'show ip route bgp'"), ['imish', '-e', 'show ip route bgp']);
    });

    test('quotes and backslashes behave as a shell would', () {
      expect(Argv.split('a "b c" d'), ['a', 'b c', 'd']);
      expect(Argv.split(r'one\ two'), ['one two']);
      expect(Argv.split(r"'a\b'"), [r'a\b']);
      expect(Argv.split('"" x'), ['', 'x']);
      expect(Argv.split('"unterminated'), ['unterminated']);
    });

    test('joining is what splitting undoes', () {
      for (final line in [
        ['imish', '-e', 'en', '-e', 'show ip bgp summary'],
        ['tmctl', '-d', 'blade', 'tmm_stat'],
        ['echo', 'a b', 'c'],
        ['weird', 'quote"inside'],
      ]) {
        expect(Argv.split(Argv.join(line)), line);
      }
    });
  });

  group('k0rdent', () {
    test('reads the Sveltos agent flags', () {
      const args = ['--diagnostics-address=:8443', '--v=0',
        '--cluster-namespace=kcm-system', '--cluster-name=example-cluster',
        '--cluster-type=Capi', '--current-cluster=managed-cluster'];
      expect(K0rdent.flag('--cluster-namespace', args), 'kcm-system');
      expect(K0rdent.flag('--cluster-name', args), 'example-cluster');
      expect(K0rdent.flag('--cluster-type', args), 'Capi');
      expect(K0rdent.flag('--missing', args), isNull);
      // A prefix that is not the whole flag name must not match.
      expect(K0rdent.flag('--cluster', args), isNull);
    });

    test('reads args off a deployment', () {
      final deployment = Deployment.fromJson(json('''
{"metadata": {"name": "sveltos-agent-manager", "namespace": "projectsveltos"},
 "spec": {"replicas": 1, "template": {"spec": {"containers": [
   {"name": "manager", "image": "projectsveltos/sveltos-agent:v1.12.0",
    "args": ["--cluster-name=example-cluster", "--current-cluster=managed-cluster"]}]}}}}
'''));
      expect(deployment.podArgs, contains('--current-cluster=managed-cluster'));
    });

    test('tells the editions apart by chart name', () {
      final list = listItems(json('''
{"items": [{"metadata": {"name": "k0rdent-enterprise-2-1-0-rc1-2"},
            "spec": {"version": "2.1.0-rc1.2",
                     "kcm": {"template": "k0rdent-enterprise-2-1-0-rc1-2"},
                     "providers": [{"template": "projectsveltos-1-12-1"}]}}]}
'''), K0rdentRelease.fromJson);
      final release = list.first;
      expect(release.version, '2.1.0-rc1.2');
      expect(release.kcmTemplate, startsWith('k0rdent-enterprise'));
      expect(release.providerTemplates, ['projectsveltos-1-12-1']);
    });

    test('decodes the Management singleton', () {
      final management = K0rdentManagement.fromJson(json('''
{"metadata": {"name": "kcm"},
 "spec": {"release": "k0rdent-enterprise-2-1-0-rc1-2"},
 "status": {"release": "k0rdent-enterprise-2-1-0-rc1-2",
            "availableProviders": ["infrastructure-nico", "infrastructure-internal"],
            "conditions": [{"type": "Ready", "status": "True"}]}}
'''));
      expect(management.isReady, isTrue);
      expect(management.availableProviders, contains('infrastructure-nico'));
    });

    test('reads preferred versions from discovery', () {
      final list = APIGroupList.fromJson(json('''
{"groups": [
  {"name": "k0rdent.mirantis.com", "preferredVersion": {"groupVersion": "k0rdent.mirantis.com/v1beta1"}},
  {"name": "kubevirt.io", "preferredVersion": {"groupVersion": "kubevirt.io/v1"}},
  {"name": "nothing.example.com"}]}
'''));
      final map = preferredVersions(list);
      expect(map[K0rdent.group], 'k0rdent.mirantis.com/v1beta1');
      expect(map[KubeVirt.group], 'kubevirt.io/v1');
      expect(map['nothing.example.com'], isNull);
    });

    test('summarises what it found', () {
      final f = K0rdentFingerprint()
        ..role = K0rdentRole.management
        ..edition = K0rdentEdition.enterprise
        ..version = '2.1.0';
      expect(f.summary, 'Enterprise 2.1.0');
      final m = K0rdentFingerprint()
        ..role = K0rdentRole.managed
        ..managedBy = const ManagedBy(namespace: 'kcm-system', name: 'edge');
      expect(m.summary, 'managed as kcm-system/edge');
      expect(K0rdentFingerprint().summary, 'not k0rdent');
    });
  });

  group('API discovery', () {
    /// `/apis` is assembled by the apiserver out of whatever the aggregated
    /// APIServices register, so a repeated group name is somebody else's bug,
    /// and it must not take the app down.
    test('survives a group that is listed twice', () {
      final list = APIGroupList.fromJson(json('''
{"groups": [{"name": "kubevirt.io", "preferredVersion": {"groupVersion": "kubevirt.io/v1"}},
            {"name": "kubevirt.io", "preferredVersion": {"groupVersion": "kubevirt.io/v1alpha3"}}]}
'''));
      expect(preferredVersions(list), {'kubevirt.io': 'kubevirt.io/v1'});
    });
  });

  group('KubeVirt', () {
    const vmiJson = '''
{"metadata": {"name": "tenant-a", "namespace": "default"},
 "spec": {"domain": {"cpu": {"cores": 2, "model": "host-model"},
                     "memory": {"guest": "4Gi", "maxGuest": "16Gi"},
                     "machine": {"type": "q35"},
                     "devices": {"gpus": [{"name": "a4000",
                                           "deviceName": "nvidia.com/GA104GL_RTX_A4000"}],
                                 "interfaces": [{"name": "default", "masquerade": {}},
                                                {"name": "acme", "bridge": {}}],
                                 "disks": [{"name": "rootdisk", "disk": {"bus": "virtio"}},
                                           {"name": "cloudinit", "disk": {"bus": "virtio"}}]}},
          "networks": [{"name": "default", "pod": {}},
                       {"name": "acme", "multus": {"networkName": "tenant-a"}}],
          "volumes": [{"name": "rootdisk", "containerDisk": {"image": "quay.io/example/fedora:latest"}},
                      {"name": "cloudinit", "cloudInitNoCloud": {"userData": "#cloud-config"}}]},
 "status": {"phase": "Running", "nodeName": "worker-1",
            "interfaces": [{"name": "default", "ipAddress": "203.0.113.82", "ipAddresses": ["203.0.113.82"],
                            "mac": "02:00:00:00:00:01", "linkState": "up", "queueCount": 1},
                           {"name": "acme", "ipAddress": "198.51.100.101",
                            "mac": "02:00:00:00:00:02", "linkState": "up"}],
            "memory": {"guestAtBoot": "4Gi", "guestCurrent": "4Gi", "guestRequested": "4Gi"},
            "machine": {"type": "q35"},
            "launcherContainerImageVersion": "1.8.4",
            "migrationMethod": "BlockMigration",
            "conditions": [{"type": "Ready", "status": "True"},
                           {"type": "LiveMigratable", "status": "False", "reason": "HostDeviceNotLiveMigratable"}],
            "phaseTransitionTimestamps": [{"phase": "Scheduling", "phaseTransitionTimestamp": "2026-09-04T03:23:18Z"},
                                          {"phase": "Running", "phaseTransitionTimestamp": "2026-09-04T03:23:32Z"}],
            "volumeStatus": [{"name": "cloudinit", "size": 1048576, "target": "vdb"},
                             {"name": "rootdisk", "target": "vda"}]}}
''';

    test('counts GPUs under either naming scheme', () {
      final node = Node.fromJson(json('''
{"metadata": {"name": "worker-1"},
 "status": {"allocatable": {"cpu": "48", "memory": "65536000Ki",
                            "devices.kubevirt.io/kvm": "1k",
                            "nvidia.com/GA104GL_RTX_A4000": "2",
                            "nvidia.com/gpu": "0"}}}
'''));
      final gpus = node.gpuResources;
      expect(gpus.length, 1);
      expect(gpus.first.name, 'GA104GL_RTX_A4000');
      expect(gpus.first.count, 2);
    });

    test('does not mistake BlueField functions for GPUs', () {
      final node = Node.fromJson(json('''
{"metadata": {"name": "dpu-node-1"},
 "status": {"allocatable": {"cpu": "14", "nvidia.com/bf_sf": "26", "nvidia.com/bf_sf_trusted": "12"}}}
'''));
      expect(node.gpuResources, isEmpty);
    });

    test('decodes a running instance with a passed-through card', () {
      final vmi = VirtualMachineInstance.fromJson(json(vmiJson));
      expect(vmi.isRunning, isTrue);
      expect(vmi.node, 'worker-1');
      expect(vmi.size, '2 vCPU · 4Gi');
      expect(vmi.gpus.first.deviceName, 'nvidia.com/GA104GL_RTX_A4000');
      expect(vmi.addresses.map((a) => a.ip), ['203.0.113.82', '198.51.100.101']);
      expect(vmi.spec?.networks?.map((n) => n.described), ['pod', 'tenant-a']);
    });

    test('keeps an instance that has no VirtualMachine', () {
      final vmi = VirtualMachineInstance.fromJson(json(vmiJson));
      final standalone = Machine(namespace: 'default', name: 'tenant-a', vmi: vmi);
      expect(standalone.isManageable, isFalse);
      expect(standalone.isRunning, isTrue);
      expect(standalone.state, 'Running');
    });

    test('reads a stopped machine off its template', () {
      final vm = VirtualMachine.fromJson(json('''
{"metadata": {"name": "halted", "namespace": "default"},
 "spec": {"runStrategy": "Halted",
          "template": {"spec": {"domain": {"devices": {"gpus": [
              {"name": "a4000", "deviceName": "nvidia.com/GA104GL_RTX_A4000"}]}},
            "networks": [{"name": "seg", "multus": {"networkName": "tenant-b"}}]}}},
 "status": {"printableStatus": "Stopped"}}
'''));
      final machine = Machine(namespace: 'default', name: 'halted', vm: vm);
      expect(machine.isManageable, isTrue);
      expect(machine.isRunning, isFalse);
      expect(machine.state, 'Stopped');
      expect(machine.gpus.length, 1);
      expect(machine.networks.map((n) => n.described), ['tenant-b']);
    });

    test('separates the declared state from the instance phase', () {
      final vm = VirtualMachine.fromJson(json('''
{"metadata": {"name": "gpu-1", "namespace": "default"}, "spec": {"running": true},
 "status": {"printableStatus": "Starting"}}'''));
      final vmi = VirtualMachineInstance.fromJson(json('''
{"metadata": {"name": "gpu-1", "namespace": "default"}, "status": {"phase": "Scheduling"}}'''));
      final stuck = Machine(namespace: 'default', name: 'gpu-1', vm: vm, vmi: vmi);
      expect(stuck.isRunning, isFalse);
      expect(stuck.isDeclaredRunning, isTrue);
      expect(stuck.state, 'Scheduling');
    });

    test('reads the declared state of a manually run machine off its status', () {
      VirtualMachine decode(String s) => VirtualMachine.fromJson(json(s));
      expect(decode('{"metadata": {"name": "m"}, "spec": {"runStrategy": "Manual"}, "status": {"created": false, "printableStatus": "Stopped"}}').isRunning, isFalse);
      expect(decode('{"metadata": {"name": "m"}, "spec": {"runStrategy": "Manual"}, "status": {"created": true, "printableStatus": "Starting"}}').isRunning, isTrue);
      expect(decode('{"metadata": {"name": "m"}, "spec": {"runStrategy": "Always"}}').isRunning, isTrue);
    });

    test('reads the declared state off whichever object exists', () {
      final vm = VirtualMachine.fromJson(json('''
{"metadata": {"name": "halted", "namespace": "default"}, "spec": {"runStrategy": "Halted"}, "status": {"printableStatus": "Stopped"}}'''));
      expect(Machine(namespace: 'default', name: 'halted', vm: vm).isDeclaredRunning, isFalse);
      final vmi = VirtualMachineInstance.fromJson(json(vmiJson));
      expect(Machine(namespace: 'default', name: 'tenant-a', vmi: vmi).isDeclaredRunning, isTrue);
    });

    test('reads interfaces with their bindings', () {
      final vmi = VirtualMachineInstance.fromJson(json(vmiJson));
      final ifaces = vmi.interfaces;
      expect(ifaces.map((i) => i.name), ['default', 'acme']);
      expect(ifaces[0].binding, InterfaceBinding.masquerade);
      expect(ifaces[0].network, 'pod');
      expect(ifaces[0].addresses, ['203.0.113.82']);
      expect(ifaces[1].binding, InterfaceBinding.bridge);
      expect(ifaces[1].network, 'tenant-a');
      expect(ifaces[1].mac, '02:00:00:00:00:02');
      expect(ifaces[1].linkState, 'up');
    });

    test('names a virtual function and a plugin binding', () {
      final ifaces = asListPublic('''
[{"name": "vf", "sriov": {}, "macAddress": "02:00:00:00:00:0a"},
 {"name": "pt", "binding": {"name": "passt"}},
 {"name": "odd"}]
''', VmInterface.fromJson);
      expect(ifaces[0].binding, InterfaceBinding.sriov);
      expect(ifaces[0].describedBinding, 'SR-IOV VF');
      expect(ifaces[0].macAddress, '02:00:00:00:00:0a');
      expect(ifaces[1].binding, InterfaceBinding.plugin);
      expect(ifaces[1].describedBinding, 'passt');
      expect(ifaces[2].binding, InterfaceBinding.unknown);
    });

    test('reads disks and whether they survive a stop', () {
      final vmi = VirtualMachineInstance.fromJson(json(vmiJson));
      final disks = vmi.disks;
      expect(disks.map((d) => d.name), ['rootdisk', 'cloudinit']);
      expect(disks[0].target, 'vda');
      expect(disks[0].bus, 'virtio');
      expect(disks[0].backing, startsWith('containerDisk quay.io/'));
      expect(disks[0].isEphemeral, isTrue);
      expect(disks[1].backing, 'cloud-init');
      expect(disks[1].bytes, 1048576);
      expect(Machine(namespace: 'default', name: 'tenant-a', vmi: vmi).bootsFromEphemeralDisk, isTrue);
    });

    test('reads attachment definitions', () {
      final nads = listItems(json(r'''
{"items": [
  {"metadata": {"name": "tenant-a", "namespace": "default"},
   "spec": {"config": "{\"cniVersion\":\"0.3.1\",\"type\":\"bridge\",\"bridge\":\"br-acme\",\"mtu\":9000,\"macspoofchk\":false}"}},
  {"metadata": {"name": "sf-vf", "namespace": "default",
                "annotations": {"k8s.v1.cni.cncf.io/resourceName": "nvidia.com/bf_sf"}},
   "spec": {"config": "{\"cniVersion\":\"0.3.1\",\"name\":\"sf\",\"plugins\":[{\"type\":\"sriov\",\"vlan\":100,\"spoofchk\":\"off\"},{\"type\":\"tuning\"}]}"}}
]}
'''), NetworkAttachment.fromJson);
      expect(nads[0].type, 'bridge');
      expect(nads[0].bridge, 'br-acme');
      expect(nads[0].mtu, 9000);
      expect(nads[0].resourceName, isNull);
      expect(nads[1].type, 'sriov');
      expect(nads[1].vlan, 100);
      expect(nads[1].resourceName, 'nvidia.com/bf_sf');
    });

    test('reads what the CNI gave the pod', () {
      final nets = PodNetwork.parse('''
[{"name": "kube-bridge", "interface": "eth0", "ips": ["10.245.0.82"], "mac": "ee:29:3a:4d:e8:8c", "default": true, "dns": {}},
 {"name": "default/sf-vf", "interface": "net1", "mac": "02:00:00:00:00:0a", "dns": {},
  "device-info": {"type": "pci", "version": "1.1.0",
                  "pci": {"pci-address": "0000:03:02.4", "pf-pci-address": "0000:03:00.0"}}}]
''');
      expect(nets.length, 2);
      expect(nets[0].device, isNull);
      expect(nets[1].interface, 'net1');
      expect(nets[1].device?.pciAddress, '0000:03:02.4');
      expect(nets[1].device?.pfAddress, '0000:03:00.0');
      expect(PodNetwork.parse(null), isEmpty);
      expect(PodNetwork.parse('not json'), isEmpty);
    });

    test('joins a virtual function to its resource and address', () {
      final vmi = VirtualMachineInstance.fromJson(json('''
{"metadata": {"name": "gpu-1", "namespace": "default"},
 "spec": {"domain": {"devices": {"interfaces": [{"name": "default", "masquerade": {}},
                                                {"name": "fast", "sriov": {}}]}},
          "networks": [{"name": "default", "pod": {}},
                       {"name": "fast", "multus": {"networkName": "sf-vf"}}]},
 "status": {"phase": "Running",
            "interfaces": [{"name": "default", "ipAddress": "10.245.0.90", "podInterfaceName": "eth0"},
                           {"name": "fast", "mac": "02:00:00:00:00:0a", "linkState": "up", "podInterfaceName": "net1"}]}}
'''));
      const nad = NetworkAttachment(namespace: 'default', name: 'sf-vf', type: 'sriov',
          resourceName: 'nvidia.com/bf_sf', vlan: 100);
      final pods = PodNetwork.parse('''
[{"name": "kube-bridge", "interface": "eth0"},
 {"name": "default/sf-vf", "interface": "net1",
  "device-info": {"type": "pci", "pci": {"pci-address": "0000:03:02.4", "pf-pci-address": "0000:03:00.0"}}}]
''');
      final machine = Machine(namespace: 'default', name: 'gpu-1', vmi: vmi,
          attachments: const [nad], podNetworks: pods);
      final fast = machine.interfaces.last;
      expect(fast.binding, InterfaceBinding.sriov);
      expect(fast.attachment?.resourceName, 'nvidia.com/bf_sf');
      expect(fast.device?.pciAddress, '0000:03:02.4');
      expect(fast.details, ['nvidia.com/bf_sf', 'PCI 0000:03:02.4', 'PF 0000:03:00.0', 'VLAN 100']);
      expect(machine.interfaces.first.details, isEmpty);
    });

    test('reads the platform facts', () {
      final vmi = VirtualMachineInstance.fromJson(json(vmiJson));
      expect(vmi.cpuModel, 'host-model');
      expect(vmi.machineType, 'q35');
      expect(vmi.memory, '4Gi of 16Gi');
      expect(vmi.runningSince, isNotNull);
      expect(vmi.isLiveMigratable, isFalse);
      expect(vmi.launcherVersion, '1.8.4');
    });
  });

  group('Certificate', () {
    test('reads names and dates out of DER', () {
      final server = Certificate.firstInPem(File('test/fixtures/tls/server-cert.txt').readAsBytesSync());
      expect(server.subject, 'apiserver.test');
      expect(server.issuer, 'bnkfield test CA');
      expect(server.notAfter.difference(server.notBefore).inDays, 800);
      expect(server.isExpired, isFalse);
      expect(server.daysRemaining, greaterThan(0));
      final ca = Certificate.firstInPem(File('test/fixtures/tls/ca-cert.txt').readAsBytesSync());
      expect(ca.subject, ca.issuer);
      expect(ca.notAfter.difference(ca.notBefore).inDays, 3650);
    });

    test('refuses a PEM without a certificate in it', () {
      expect(() => Certificate.firstInPem(utf8.encode('nothing here')),
          throwsA(isA<DerException>()));
    });
  });

  group('Resources', () {
    test('renders an object as YAML without managedFields', () {
      final object = RawObject.tryFrom(json('''
{"metadata": {"name": "web", "namespace": "default", "creationTimestamp": "2026-09-04T03:23:18Z",
              "managedFields": [{"manager": "kubectl"}]},
 "spec": {"replicas": 2, "paused": null, "selector": {"matchLabels": {"app": "web"}}}}
'''))!;
      expect(object.id, 'default/web');
      expect(object.created, isNotNull);
      expect(object.integer(['spec', 'replicas']), 2);
      expect(object.string(['metadata', 'namespace']), 'default');
      final yaml = object.yaml;
      expect(yaml, isNot(contains('managedFields')));
      expect(yaml, isNot(contains('paused')));
      expect(yaml.indexOf('metadata:'), lessThan(yaml.indexOf('spec:')));
      expect(yaml, contains('    matchLabels:\n      app: web'));
    });

    test('kinds know their paths', () {
      expect(ResourceKind.all.first.path(null), '/api/v1/nodes');
      expect(ResourceKind.all[1].path('kube-system'), '/api/v1/namespaces/kube-system/pods');
      expect(ResourceKind.all[2].path(''), '/apis/apps/v1/deployments');
      expect(ResourceKind.all.map((k) => k.plural), isNot(contains('secrets')));
    });
  });

  group('Exporter', () {
    Pod pod(String spec) => Pod.fromJson(json('{"metadata": {"name": "tmm", "namespace": "ns"}, "spec": $spec}'));

    test('tells a permanent sidecar from an ephemeral one', () {
      expect(Exporter.installation(pod('{"containers": [{"name": "tmm-stat-exporter", "image": "x"}]}')),
          isA<PermanentInstallation>());
      expect(Exporter.installation(pod('{"containers": [], "ephemeralContainers": [{"name": "tmm-stat-exporter"}]}')),
          isA<EphemeralInstallation>());
      expect(Exporter.installation(pod('{"containers": [{"name": "f5-tmm"}]}')), isA<AbsentInstallation>());
      expect(Exporter.runningImage(pod('{"containers": [{"name": "tmm-stat-exporter", "image": "x"}]}')), 'x');
    });

    test('the container spec has no probes and no resources', () {
      final c = Exporter.container(clusterLabel: 'lab', dssmCert: true);
      expect(c['name'], Exporter.containerName);
      expect(c.containsKey('resources'), isFalse);
      expect(c.containsKey('readinessProbe'), isFalse);
      expect((c['volumeMounts'] as List).length, 2);
      final env = (c['env'] as List).cast<Map>();
      expect(env.last['value'], 'cluster=lab,pod=\$(POD_NAME),node=\$(NODE_NAME)');
      // Round-trips as JSON, which is what the patch is.
      expect(jsonDecode(jsonEncode(c)), isA<Map>());
    });
  });

  group('Client URLs', () {
    KubeClient client(String server) => KubeClient(KubeContext(
        name: 'c', clusterName: 'c', server: Uri.parse(server), caPEM: null,
        tlsServerName: null, insecureSkipTLSVerify: false, namespace: null,
        auth: const BearerTokenAuth('t')));

    test('sorts query keys and repeats list values', () {
      final c = client('https://h:6443');
      expect(c.url('/api/v1/pods', {'labelSelector': 'a=b', 'fieldSelector': 'x'}).toString(),
          'https://h:6443/api/v1/pods?fieldSelector=x&labelSelector=a%3Db');
      expect(c.url('/x', {'command': ['sh', '-c', 'ls'], 'tty': 'false'}).query,
          'command=sh&command=-c&command=ls&tty=false');
      expect(c.url('/version').toString(), 'https://h:6443/version');
      c.close();
    });

    test('keeps a path prefix on the server', () {
      final c = client('https://h/k8s/clusters/c-abc/');
      expect(c.url('/version').toString(), 'https://h/k8s/clusters/c-abc/version');
      c.close();
    });

    test('refuses to build a request for an unusable context', () {
      final c = KubeClient(KubeContext(
          name: 'c', clusterName: 'c', server: Uri.parse('https://h'), caPEM: null,
          tlsServerName: null, insecureSkipTLSVerify: false, namespace: null,
          auth: const UnsupportedAuth('needs aws')));
      expect(() => c.get('/version'), throwsA(isA<UnusableFailure>()));
      c.close();
    });
  });
}

List<T> asListPublic<T>(String text, T Function(JsonMap) parse) => [
      for (final e in jsonDecode(text) as List) parse(Map<String, dynamic>.from(e as Map))
    ];
