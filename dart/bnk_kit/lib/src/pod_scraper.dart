import 'gzip.dart';
import 'kube_client.dart';
import 'log.dart';
import 'port_forward.dart';
import 'prom_text.dart';

/// Scrapes one pod's exporter, over a tunnel it keeps.
///
/// Field's first version opened a port-forward per scrape and closed it again.
/// That works, and on the simulator it costs about a second, but on an iPad
/// over wifi it took the whole loop to roughly 5.5 s between samples, measured
/// from the apiserver's own `portforward` request counter. Almost none of that
/// was the 14 KB of metrics; it was the WebSocket upgrade through the
/// apiserver and the kubelet dialling into the pod, paid again every two
/// seconds.
///
/// So the tunnel is held. A tunnel that breaks, the pod restarted, the kubelet
/// dropped it, the network moved, is discarded and rebuilt on the next scrape
/// rather than reported as a failure, because from the caller's side a dropped
/// tunnel and a slow one should look the same: a scrape that took longer.
class PodScraper {
  final KubeClient client;
  final String namespace;
  final String pod;
  final int port;

  PortForward? _tunnel;
  int _reconnects = 0;

  PodScraper(
      {required this.client,
      required this.namespace,
      required this.pod,
      this.port = 9099});

  int get reconnects => _reconnects;

  /// One scrape. Reuses the open tunnel, or opens one.
  ///
  /// Retried exactly once on a transport failure: the common case is a tunnel
  /// that went stale between scrapes, where a second attempt on a fresh one
  /// succeeds. A second failure is real and is reported.
  Future<List<Sample>> scrape({String path = '/metrics'}) async {
    try {
      return await _attempt(path);
    } on PortForwardException catch (first) {
      Log.telemetry.info('$pod: $first; rebuilding the tunnel');
      await _discard();
      _reconnects++;
      try {
        return await _attempt(path);
      } catch (e) {
        Log.telemetry.severe('$pod: retry failed: $e');
        rethrow;
      }
    } catch (e) {
      Log.telemetry.severe('$pod: scrape failed: $e');
      rethrow;
    }
  }

  Future<List<Sample>> _attempt(String path) async {
    final pipe = await _open();
    final reply = await pipe.get(path, headers: const {
      'Accept-Encoding': 'gzip',
      'Accept': 'text/plain',
    });
    if (reply.status != 200) {
      throw KubeFailure.http(reply.status, String.fromCharCodes(reply.body));
    }
    final body = reply.isGzipped ? Gzip.inflate(reply.body) : reply.body;
    return PromText.parseBytes(body);
  }

  Future<PortForward> _open() async {
    final held = _tunnel;
    if (held != null && held.isUsable) return held;
    Log.telemetry.info('$pod: opening a tunnel to :$port');
    final fresh = client.portForward(namespace: namespace, pod: pod, port: port);
    await fresh.connect();
    _tunnel = fresh;
    return fresh;
  }

  Future<void> _discard() async {
    await _tunnel?.close();
    _tunnel = null;
  }

  /// Let go of the tunnel. Called when the app stops watching, so a pod is not
  /// left holding a kubelet stream for a screen nobody is looking at.
  Future<void> stop() => _discard();
}

extension ScrapeApi on KubeClient {
  /// Scrape a port inside a pod, through the apiserver.
  ///
  /// One-shot: opens a tunnel, reads, closes. Fine for a probe or a test, but
  /// a repeated scrape should hold a [PodScraper] instead; the tunnel setup
  /// dominates everything else on a real device.
  Future<List<Sample>> scrape(
      {required String namespace,
      required String pod,
      required int port,
      String path = '/metrics'}) async {
    final scraper =
        PodScraper(client: this, namespace: namespace, pod: pod, port: port);
    try {
      return await scraper.scrape(path: path);
    } finally {
      await scraper.stop();
    }
  }
}
