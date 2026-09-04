/// The transport against a fake apiserver on loopback: mutual TLS from PEM
/// bytes, the CA pin, the tls-server-name override, and the three upgraded
/// channels over real sockets. This is the test the Swift package could not
/// write, because its identity lived in a keychain.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bnk_kit/bnk_kit.dart';
import 'package:bnk_kit/testing.dart';
import 'package:test/test.dart';

const fixtures = Fixtures('test/fixtures');

Uint8List fixture(String name) => fixtures.tls(name);

KubeContext contextFor(FakeApiserver api,
        {KubeAuth? auth, bool pinCA = true, String? tlsServerName, bool insecure = false}) =>
    fixtures.context(api, auth: auth, pinCA: pinCA, tlsServerName: tlsServerName, insecure: insecure);

void main() {
  late FakeApiserver api;

  setUpAll(() async {
    api = FakeApiserver(fixtures: fixtures);
    await api.start();
  });

  tearDownAll(() => api.stop());

  test('presents the client certificate from PEM bytes and pins the CA', () async {
    final client = KubeClient(contextFor(api, tlsServerName: 'apiserver.test'));
    final who = jsonDecode(utf8.decode(await client.get('/whoami'))) as Map;
    expect(who['certificate'], 'bnkfield test client');
    expect(who['authorization'], isNull);
    expect(who['userAgent'], KubeClient.userAgent);
    final version = await client.version();
    expect(version.gitVersion, 'v1.30.0-fake');
    final nodes = await client.nodes();
    expect(nodes.where((n) => n.isReady).length, 1);
    client.close();
  });

  test('sends a bearer token when that is what the kubeconfig carries', () async {
    final client = KubeClient(contextFor(api,
        auth: const BearerTokenAuth('secret-token'), tlsServerName: 'apiserver.test'));
    final who = jsonDecode(utf8.decode(await client.get('/whoami'))) as Map;
    expect(who['certificate'], isNull);
    expect(who['authorization'], 'Bearer secret-token');
    client.close();
  });

  /// The server's certificate names `apiserver.test`, and the client dials
  /// 127.0.0.1. Without the override that is a mismatch and must fail; with
  /// it, the name the kubeconfig gives is the one checked.
  test('honours tls-server-name, and refuses the connection without it', () async {
    final mismatched = KubeClient(contextFor(api));
    await expectLater(mismatched.get('/version'), throwsA(isA<HandshakeException>()));
    mismatched.close();
  });

  test('refuses a server whose CA is not the pinned one', () async {
    // The system roots do not contain the test CA either, so an unpinned
    // context must also fail: nothing with a public certificate gets in.
    final unpinned = KubeClient(contextFor(api, pinCA: false, tlsServerName: 'apiserver.test'));
    await expectLater(unpinned.get('/version'), throwsA(isA<HandshakeException>()));
    unpinned.close();
  });

  test('insecure-skip-tls-verify accepts anything', () async {
    final client = KubeClient(contextFor(api, pinCA: false, insecure: true));
    expect((await client.version()).gitVersion, 'v1.30.0-fake');
    client.close();
  });

  test('reports the status and body of a refusal', () async {
    final client = KubeClient(contextFor(api, tlsServerName: 'apiserver.test'));
    await expectLater(
        client.get('/forbidden'),
        throwsA(isA<HttpFailure>()
            .having((f) => f.code, 'code', 403)
            .having((f) => f.toString(), 'text', contains('forbidden'))));
    client.close();
  });

  test('scrapes over a held tunnel, gzipped and chunked, then plain, then reuses it', () async {
    final client = KubeClient(contextFor(api, tlsServerName: 'apiserver.test'));
    final scraper = PodScraper(client: client, namespace: 'ns', pod: 'tmm', port: 9099);
    final samples = await scraper.scrape();
    expect(samples.length, greaterThan(500));
    expect(samples.any((s) => s.name == 'f5tmm_up' && s.value == 1), isTrue);

    final again = await scraper.scrape(path: '/plain');
    expect(again, [const Sample('plain_metric', {}, 42)]);
    expect(scraper.reconnects, 0);
    expect(api.portForwardRequests, 1, reason: 'one tunnel served both scrapes');

    // A 404 with Connection: close ends the tunnel; the next scrape rebuilds it.
    await expectLater(scraper.scrape(path: '/missing'), throwsA(isA<HttpFailure>()));
    final rebuilt = await scraper.scrape(path: '/plain');
    expect(rebuilt.length, 1);
    expect(api.portForwardRequests, 2);
    await scraper.stop();
    client.close();
  });

  test('one-shot scrape opens and closes its own tunnel', () async {
    final client = KubeClient(contextFor(api, tlsServerName: 'apiserver.test'));
    final before = api.portForwardRequests;
    final samples = await client.scrape(namespace: 'ns', pod: 'tmm', port: 9099, path: '/plain');
    expect(samples.single.name, 'plain_metric');
    expect(api.portForwardRequests, before + 1);
    client.close();
  });

  test('exec streams stdout and stderr and reports the exit', () async {
    final client = KubeClient(contextFor(api, tlsServerName: 'apiserver.test'));
    final chunks = await client
        .exec(namespace: 'ns', pod: 'tmm', container: 'f5-tmm', command: ['tmctl', '-d', 'blade'])
        .toList();
    expect(chunks.map((c) => c.source), [ExecSource.stdout, ExecSource.stderr]);
    expect(chunks.first.text, 'ran: tmctl -d blade\n');

    await expectLater(
        client.exec(namespace: 'ns', pod: 'tmm', container: null, command: ['false']).toList(),
        throwsA(isA<ExecException>().having((e) => e.message, 'message', contains('exit code 1'))));
    client.close();
  });

  test('follows a log, parsing what it can and keeping the rest', () async {
    final client = KubeClient(contextFor(api, tlsServerName: 'apiserver.test'));
    final lines = await client.logStream(namespace: 'ns', pod: 'p', container: 'c').toList();
    expect(lines.length, 3);
    expect(lines[0].at, isNotNull);
    expect(lines[0].text, 'first line');
    expect(lines[1].level, LogLevel.error);
    expect(lines[2].at, isNull);
    expect(lines[2].text, 'no stamp at all');

    // Cancelling after the first line must not hang.
    final first = await client.logStream(namespace: 'ns', pod: 'p').first
        .timeout(const Duration(seconds: 5));
    expect(first.pod, 'p');
    client.close();
  });
}
