// A command-line front end for bnk_kit, so the transport can be exercised
// against real clusters before any of it is behind a view. Everything it
// calls is the same code the app will run; only the presentation is
// throwaway. It never touches a keychain, so unlike the Swift harness it is
// safe to point at the kubeconfig the app itself uses.

import 'dart:async';
import 'dart:io';

import 'package:bnk_kit/bnk_kit.dart';
import 'package:logging/logging.dart';

Never die(String message) {
  stderr.writeln('error: $message');
  exit(1);
}

const usage = '''
usage: bnkfield <command>

  contexts       <kubeconfig>
  probe          <kubeconfig> <context>
  pods           <kubeconfig> <context> [namespace] [labelSelector]
  scrape         <kubeconfig> <context> <namespace> <pod> [port]
  bench          <kubeconfig> <context> <namespace> <pod> [port]
  hold           <kubeconfig> <context> <namespace> <pod> [port]
  logs           <kubeconfig> <context> <namespace>
  exec           <kubeconfig> <context> <namespace> <pod> <container> <cmd...>
  nico           <kubeconfig> <context>
  install-dryrun <kubeconfig> <context>
  install        <kubeconfig> <context>          adds the exporter to every f5-tmm pod without one
  dpu            <kubeconfig> <context>
  get            <kubeconfig> <context> <kind> [namespace]
''';

Future<KubeContext> loadContext(String path, String name) async {
  final cfg = await Kubeconfig.load(path);
  final ctx = cfg.context(name);
  if (ctx == null) {
    die('no context "$name" — have: ${cfg.contexts.map((c) => c.name).join(', ')}');
  }
  return ctx;
}

String pad(String s, int n) => s.length >= n ? s : s + ' ' * (n - s.length);

Future<void> main(List<String> argv) async {
  try {
    await run(argv);
  } catch (e) {
    die('$e');
  }
}

Future<void> run(List<String> argv) async {
  if (Platform.environment['BNKFIELD_DEBUG'] != null) {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((r) => stderr.writeln('[${r.level.name}] ${r.message}'));
  }
  if (argv.isEmpty) {
    print(usage);
    exit(2);
  }
  final command = argv.first;
  final args = argv.sublist(1);

  switch (command) {
    case 'contexts':
      if (args.length != 1) die(usage);
      final cfg = await Kubeconfig.load(args[0]);
      for (final c in cfg.contexts) {
        final auth = switch (c.auth) {
          ClientCertificateAuth() => 'client certificate',
          BearerTokenAuth() => 'bearer token',
          UnsupportedAuth(:final reason) => 'UNUSABLE — $reason',
        };
        print('${pad(c.name, 26)} ${pad(c.server.toString(), 34)} $auth');
      }

    case 'probe':
      if (args.length != 2) die(usage);
      final client = KubeClient(await loadContext(args[0], args[1]));
      final version = await client.version();
      final nodes = await client.nodes();
      print('server      ${version.gitVersion}');
      print('nodes       ${nodes.length} (${nodes.where((n) => n.isReady).length} ready)');
      for (final n in nodes) {
        print('  ${pad(n.metadata.name, 40)} ${n.status?.nodeInfo?.architecture ?? '?'}  ${n.status?.nodeInfo?.osImage ?? ''}');
      }
      client.close();

    case 'pods':
      if (args.length < 2) die(usage);
      final client = KubeClient(await loadContext(args[0], args[1]));
      final ns = args.length > 2 && args[2] != '-' ? args[2] : null;
      final sel = args.length > 3 ? args[3] : null;
      final pods = await client.pods(namespace: ns, labelSelector: sel);
      print('${pods.length} pods');
      for (final p in pods.take(40)) {
        final eph = switch (p.containerKind('tmm-stat-exporter')) {
          ContainerKind.durable => '  [exporter]',
          ContainerKind.ephemeral => '  [exporter, ephemeral]',
          null => '',
        };
        final where = ns == null ? '${pad(p.metadata.namespace ?? '-', 22)} ' : '';
        print('  $where${pad(p.metadata.name, 46)} ${pad(p.ready, 6)} ${pad(p.status?.phase ?? '?', 10)} ${p.node}$eph');
      }
      client.close();

    case 'scrape':
      if (args.length < 4) die(usage);
      final client = KubeClient(await loadContext(args[0], args[1]));
      final port = args.length > 4 ? int.tryParse(args[4]) ?? 9099 : 9099;
      final started = DateTime.now();
      final samples = await client.scrape(namespace: args[2], pod: args[3], port: port);
      final elapsed = DateTime.now().difference(started).inMilliseconds / 1000;
      print('${samples.length} samples in ${elapsed.toStringAsFixed(2)}s');
      final families = <String, int>{};
      for (final s in samples) {
        families[s.name] = (families[s.name] ?? 0) + 1;
      }
      print('${families.length} metric families');
      for (final name in const [
        'f5tmm_up', 'f5tmm_tmm_client_side_traffic_cur_conns',
        'f5tmm_tmm_tm_total_cycles', 'f5tmm_scrape_duration_seconds',
      ]) {
        for (final s in samples.where((s) => s.name == name).take(2)) {
          print('  ${s.seriesKey} = ${s.value}');
        }
      }
      client.close();

    case 'bench':
      // Ten scrapes of one pod, holding the tunnel, so the cost of keeping it
      // can be compared with the cost of rebuilding it.
      if (args.length < 4) die(usage);
      final client = KubeClient(await loadContext(args[0], args[1]));
      final port = args.length > 4 ? int.tryParse(args[4]) ?? 9099 : 9099;
      final scraper = PodScraper(client: client, namespace: args[2], pod: args[3], port: port);
      final kept = <double>[];
      for (var i = 0; i < 10; i++) {
        final t = DateTime.now();
        final s = await scraper.scrape();
        kept.add(DateTime.now().difference(t).inMicroseconds / 1e6);
        if (kept.length == 1) print('samples per scrape: ${s.length}');
      }
      await scraper.stop();
      final fresh = <double>[];
      for (var i = 0; i < 10; i++) {
        final t = DateTime.now();
        await client.scrape(namespace: args[2], pod: args[3], port: port);
        fresh.add(DateTime.now().difference(t).inMicroseconds / 1e6);
      }
      String stats(List<double> xs) {
        final sorted = [...xs]..sort();
        return 'first ${xs[0].toStringAsFixed(3)}s  median ${sorted[xs.length ~/ 2].toStringAsFixed(3)}s  min ${sorted[0].toStringAsFixed(3)}s';
      }
      print('held tunnel:  ${stats(kept)}');
      print('fresh tunnel: ${stats(fresh)}');
      final freshSorted = [...fresh]..sort();
      final keptSorted = [...kept.skip(1)]..sort();
      print('steady-state speedup: ${(freshSorted[5] / keptSorted[4]).toStringAsFixed(1)}x');
      client.close();

    case 'hold':
      // Scrape one pod every 2s for 120s over a held tunnel, and say how many
      // times the tunnel had to be rebuilt.
      if (args.length < 4) die(usage);
      final client = KubeClient(await loadContext(args[0], args[1]));
      final port = args.length > 4 ? int.tryParse(args[4]) ?? 9099 : 9099;
      final scraper = PodScraper(client: client, namespace: args[2], pod: args[3], port: port);
      final deadline = DateTime.now().add(const Duration(seconds: 120));
      var n = 0, failures = 0;
      final durations = <double>[];
      while (DateTime.now().isBefore(deadline)) {
        final t = DateTime.now();
        try {
          await scraper.scrape();
          n++;
          durations.add(DateTime.now().difference(t).inMicroseconds / 1e6);
        } catch (e) {
          failures++;
          stderr.writeln('scrape failed: $e');
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      final sorted = [...durations]..sort();
      print('scrapes: $n  failures: $failures  reconnects: ${scraper.reconnects}');
      if (sorted.isNotEmpty) {
        print('per scrape: median ${sorted[sorted.length ~/ 2].toStringAsFixed(3)}s  max ${sorted.last.toStringAsFixed(3)}s');
      }
      await scraper.stop();
      client.close();

    case 'logs':
      if (args.length < 3) die(usage);
      final client = KubeClient(await loadContext(args[0], args[1]));
      final ns = args[2];
      final pods = (await client.pods(namespace: ns)).take(6).map((p) => p.metadata.name).toList();
      print('following ${pods.length} pods in $ns');
      final subscriptions = <StreamSubscription<LogLine>>[];
      final done = <Future<void>>[];
      for (final pod in pods) {
        final finished = Completer<void>();
        done.add(finished.future);
        subscriptions.add(client.logStream(namespace: ns, pod: pod, tailLines: 3).listen(
          (line) {
            final t = line.at?.toIso8601String() ?? '-';
            final text = line.text.length > 90 ? line.text.substring(0, 90) : line.text;
            print('  [${line.level.name}] $t ${pad(line.pod, 34)} $text');
          },
          onError: (Object e) {
            print('  $pod: $e');
            if (!finished.isCompleted) finished.complete();
          },
          onDone: () {
            if (!finished.isCompleted) finished.complete();
          },
        ));
      }
      await Future.any([
        Future.wait(done),
        Future<void>.delayed(const Duration(seconds: 12)),
      ]);
      for (final s in subscriptions) {
        await s.cancel();
      }
      client.close();

    case 'exec':
      if (args.length < 5) {
        die('usage: bnkfield exec <kubeconfig> <ctx> <ns> <pod> <container> <cmd...>');
      }
      final client = KubeClient(await loadContext(args[0], args[1]));
      final command = args.sublist(5);
      try {
        await for (final chunk in client.exec(
            namespace: args[2], pod: args[3], container: args[4], command: command)) {
          (chunk.source == ExecSource.stderr ? stderr : stdout).write(chunk.text);
        }
        print('\n[exit ok]');
      } catch (e) {
        print('\n[failed] $e');
      }
      client.close();

    case 'nico':
      if (args.length < 2) die(usage);
      final client = KubeClient(await loadContext(args[0], args[1]));
      final pods = await client.pods(namespace: 'nico-system');
      print('control plane: ${pods.length} pods');
      for (final p in pods.where((p) => p.status?.phase == 'Running')) {
        print('  ${pad(p.metadata.name, 44)} ${p.spec?.containers.firstOrNull?.image ?? ''}');
      }
      try {
        final secret = await client.secret(namespace: 'nico-system', name: 'tmm-lb-admin-cert');
        final pem = secret.pem('tls.crt');
        if (pem != null) {
          final cert = Certificate.firstInPem(pem);
          print('admin cert: subject=${cert.subject ?? '?'} issuer=${cert.issuer ?? '?'}');
          print('            notAfter=${cert.notAfter} daysLeft=${cert.daysRemaining} expired=${cert.isExpired}');
        }
      } catch (_) {}
      List<TenantControlPlane> tcps = const [];
      try {
        tcps = await client.tenantControlPlanes();
      } catch (_) {}
      print('tenant control planes: ${tcps.length}');
      for (final t in tcps) {
        print('  ${pad(t.metadata.name, 24)} ${t.status?.kubernetesResources?.version?.version ?? '?'} '
            '${t.isReady ? 'Ready' : 'not ready'}  ${t.status?.controlPlaneEndpoint ?? '-'}');
        final ca = t.status?.certificates?['ca']?.secretName;
        final ns = t.metadata.namespace;
        if (ca != null && ns != null) {
          try {
            final secret = await client.secret(namespace: ns, name: ca);
            final pem = secret.pem('ca.crt');
            if (pem != null) {
              final cert = Certificate.firstInPem(pem);
              print('      ca: ${cert.subject ?? '?'} expires ${cert.notAfter} (${cert.daysRemaining} days)');
            }
          } catch (_) {}
        }
      }
      client.close();

    case 'install-dryrun':
      // Validates the ephemeral-container patch against a live cluster without
      // writing anything, so the install path can be trusted before a cluster
      // that actually needs it turns up.
      if (args.length < 2) die(usage);
      final client = KubeClient(await loadContext(args[0], args[1]));
      final pods = await client.pods(labelSelector: 'app=f5-tmm');
      print('dry-running the injection against ${pods.length} f5-tmm pod(s)');
      final outcome = await Exporter.install(pods,
          clusterLabel: 'dryrun', client: client, dryRun: true);
      for (final pod in outcome.changed) {
        print('  accepted: $pod');
      }
      for (final pod in outcome.skipped) {
        print('  skipped:  $pod');
      }
      for (final f in outcome.failed) {
        final reason = f.reason.length > 200 ? f.reason.substring(0, 200) : f.reason;
        print('  REJECTED: ${f.pod}\n            $reason');
      }
      client.close();

    case 'install':
      // The app's Add button, from the command line: an ephemeral container
      // in every f5-tmm pod that has none. Nothing restarts. It is gone
      // again when a pod is recreated, and nothing re-adds it.
      if (args.length < 2) die(usage);
      final client = KubeClient(await loadContext(args[0], args[1]));
      final pods = await client.pods(labelSelector: 'app=f5-tmm');
      final outcome = await Exporter.install(pods, clusterLabel: args[1], client: client);
      for (final pod in outcome.changed) {
        print('  added to: $pod');
      }
      for (final pod in outcome.skipped) {
        print('  skipped:  $pod (already carries one)');
      }
      for (final f in outcome.failed) {
        print('  FAILED:   ${f.pod}\n            ${f.reason}');
      }
      client.close();

    case 'dpu':
      if (args.length < 2) die(usage);
      final client = KubeClient(await loadContext(args[0], args[1]));
      final chains = await client.serviceChains();
      final interfaces = await client.serviceInterfaces();
      print('service chains: ${chains.length}  (${chains.where((c) => c.isReady).length} ready)');
      for (final chain in chains) {
        print('  ${pad(chain.metadata.name, 22)} node ${chain.spec.node ?? '?'}');
        var n = 0;
        for (final sw in chain.spec.switches ?? const <ServiceSwitch>[]) {
          final ends = (sw.ports ?? const <ServicePort>[])
              .map((p) => p.serviceInterface?.described ?? '—');
          print('      switch $n mtu ${sw.serviceMTU ?? '-'}: ${ends.join('  <->  ')}');
          n++;
        }
      }
      print('service interfaces: ${interfaces.length}  (${interfaces.where((i) => i.isReady).length} ready)');
      for (final i in interfaces.take(6)) {
        print('  ${pad(i.spec.interfaceType ?? '?', 9)} ${pad(i.interfaceName, 16)} ${i.detail ?? ''}');
      }
      client.close();

    case 'get':
      if (args.length < 3) die('usage: bnkfield get <kubeconfig> <ctx> <kind> [namespace]');
      final client = KubeClient(await loadContext(args[0], args[1]));
      final kind = ResourceKind.all
          .where((k) => k.plural == args[2] || k.name.toLowerCase() == args[2])
          .firstOrNull;
      if (kind == null) {
        die('unknown kind — have: ${ResourceKind.all.map((k) => k.plural).join(', ')}');
      }
      final objects = await client.list(kind, namespace: args.length > 3 ? args[3] : null);
      print('${objects.length} ${kind.name}');
      for (final o in objects.take(4)) {
        print('  ${pad(o.namespace ?? '-', 22)} ${o.name}');
      }
      final first = objects.firstOrNull;
      if (first != null) {
        print('--- yaml of ${first.name}, first 14 lines ---');
        for (final line in first.yaml.split('\n').take(14)) {
          print('  $line');
        }
        final ns = first.namespace;
        if (ns != null) {
          final events = await client.events(about: first.name, namespace: ns);
          print('--- ${events.length} events about it ---');
          for (final e in events.take(2)) {
            final message = e.message ?? '';
            print('  ${e.type ?? '?'} ${e.reason ?? ''} — ${message.length > 70 ? message.substring(0, 70) : message}');
          }
        }
      }
      client.close();

    default:
      print(usage);
      exit(2);
  }
}
