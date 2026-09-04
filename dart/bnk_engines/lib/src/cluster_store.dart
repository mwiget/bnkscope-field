import 'dart:async';
import 'dart:io';

import 'package:bnk_kit/bnk_kit.dart';

import 'observable.dart';

/// The words that differ by machine: what to call it, where its privacy
/// switch lives, where a file comes from. Decided by the app, never here.
class DeviceWords {
  final String thisDevice;
  final String localNetworkSetting;
  final String importSource;
  const DeviceWords({required this.thisDevice, required this.localNetworkSetting, required this.importSource});

  static const generic = DeviceWords(
      thisDevice: 'this device',
      localNetworkSetting: 'the system privacy settings',
      importSource: 'from a file');
}

/// Whether the apiserver answered, and what it said about itself.
sealed class Reach {
  const Reach();
}

class Unprobed extends Reach {
  const Unprobed();
}

class Reachable extends Reach {
  final String version;
  final int nodes;
  final int ready;
  const Reachable({required this.version, required this.nodes, required this.ready});
}

class Unreachable extends Reach {
  final String why;
  const Unreachable(this.why);
}

class Unusable extends Reach {
  final String why;
  const Unusable(this.why);
}

/// What a cluster has on it, as the sidebar badges it.
///
/// Not a taxonomy: a cluster is frequently several of these at once, and the
/// useful reading is the combination. A managed cluster that is also gpu and
/// kubevirt is the one running tenant VMs on passed-through cards, which is
/// the thing worth finding in a list.
enum ClusterRole {
  bnk('BNK'),
  dpu('DPU'),
  nico('NICo'),

  /// Serves the k0rdent API: this is a management cluster.
  k0rdent('k0rdent'),

  /// Provisioned or adopted by a k0rdent management cluster elsewhere.
  managed('k0rdent-managed'),

  /// At least one node advertises a GPU as an extended resource.
  gpu('GPU'),
  kubevirt('KubeVirt');

  final String label;
  const ClusterRole(this.label);
}

/// A cluster as the app knows it: the kubeconfig context, plus whatever
/// probing it has learned.
class ManagedCluster extends Observable {
  final KubeContext context;
  final String sourceFile;
  final DeviceWords words;

  Reach _reach = const Unprobed();
  Set<ClusterRole> _roles = {};
  List<Pod> _tmmPods = const [];
  K0rdentFingerprint _k0rdent = K0rdentFingerprint();
  Map<String, String> _apiGroups = const {};
  List<String> _gpuDevices = const [];
  int _probeGeneration = 0;

  KubeClient? _cached;
  Future<void>? _probeInFlight;
  int _probeSerial = 0;

  ManagedCluster({required this.context, required this.sourceFile, this.words = DeviceWords.generic}) {
    if (context.auth case UnsupportedAuth(:final reason)) _reach = Unusable(reason);
  }

  String get id => context.name;

  Reach get reach => _reach;
  Set<ClusterRole> get roles => _roles;
  List<Pod> get tmmPods => _tmmPods;

  /// What k0rdent this cluster is, if any. Empty on a cluster k0rdent has
  /// never touched.
  K0rdentFingerprint get k0rdent => _k0rdent;

  /// The API group versions discovery reported, so a screen can address an
  /// operator's API without guessing which version it serves.
  Map<String, String> get apiGroups => _apiGroups;

  /// GPU extended resources offered across the nodes, already summed:
  /// `["GA104GL_RTX_A4000 ×2"]`.
  List<String> get gpuDevices => _gpuDevices;

  /// Bumped every time probing finishes, so a screen can tell "the facts
  /// changed" from "the selection changed".
  int get probeGeneration => _probeGeneration;

  /// What to call this cluster in the UI.
  ///
  /// Context names are written for kubectl, not for reading:
  /// `kubernetes-admin@dpu-cplane-tenant1` says one useful word and eleven
  /// that are the same on every context. The useful word is the cluster, so
  /// that is what is shown, unless the cluster is called something kubeadm
  /// picked, in which case its address is the one thing that tells it apart.
  String get displayName {
    const generic = {'kubernetes', 'default', 'cluster.local', 'kind'};
    final afterAt = context.name.split('@').last;
    for (final candidate in [afterAt, context.clusterName]) {
      if (!generic.contains(candidate)) return candidate;
    }
    final server = context.server;
    if (server.host.isNotEmpty) {
      return server.hasPort ? '${server.host}:${server.port}' : server.host;
    }
    return context.name;
  }

  bool get isUsable => _reach is! Unusable;

  KubeClient client() => _cached ??= KubeClient(context);

  /// The client, or null when one cannot be built: the certificate did not
  /// parse, or the context needs a binary.
  KubeClient? get clientOrNull {
    if (!isUsable) return null;
    try {
      return client();
    } catch (_) {
      return null;
    }
  }

  /// Probe, or join the probe already running.
  ///
  /// Two callers ask for this concurrently, the store probes everything at
  /// launch while a screen probes the cluster it needs, and two probes
  /// interleaving on one cluster left it reporting "no route" while its data
  /// sat on the screen beside the message.
  Future<void> probe() async {
    final running = _probeInFlight;
    if (running != null) return running;
    await _runProbe();
  }

  /// Probe for a caller that has just changed the cluster.
  ///
  /// Joining an in-flight probe is wrong here. That probe listed the pods
  /// before the change landed, so adopting its answer shows the cluster as
  /// it was a moment ago.
  Future<void> probeReflectingChange() async {
    final running = _probeInFlight;
    if (running != null) await running;
    await _runProbe();
  }

  /// Let the connection pool go with the cluster: an idle keep-alive is a
  /// timer nobody will use.
  @override
  void dispose() {
    _cached?.close();
    _cached = null;
    super.dispose();
  }

  Future<void> _runProbe() async {
    _probeSerial++;
    final mine = _probeSerial;
    final task = _performProbe();
    _probeInFlight = task;
    await task;
    // Only retire the handle if it is still ours: a caller that waited on us
    // has since installed its own, and clearing that one would let a third
    // caller start a duplicate probe.
    if (_probeSerial == mine) _probeInFlight = null;
  }

  /// Ask the cluster what it is.
  ///
  /// TMM, DPU and NICo are read from pod labels rather than namespace names,
  /// because on a real deployment these live on different clusters and the
  /// namespaces vary by install shape. k0rdent and KubeVirt are read from
  /// API discovery instead: both are operators, an operator's namespace is a
  /// deployment choice, and the API it serves is not.
  Future<void> _performProbe() async {
    if (!isUsable) return;
    try {
      final c = client();
      final version = await c.version();
      final nodes = await c.nodes();
      _reach = Reachable(
          version: version.gitVersion, nodes: nodes.length, ready: nodes.where((n) => n.isReady).length);
      notify();

      final found = <ClusterRole>{};
      final tmm = await c.pods(labelSelector: 'app=f5-tmm');
      if (tmm.isNotEmpty) found.add(ClusterRole.bnk);
      _tmmPods = tmm;
      // A svc.dpu.nvidia.com/ label means the workload is wired through the
      // DPU service API. It does NOT mean the DPF operator is here; that is
      // a different API group.
      if (tmm.any((p) => (p.metadata.labels ?? const {}).keys.any((k) => k.startsWith('svc.dpu.nvidia.com/')))) {
        found.add(ClusterRole.dpu);
      }
      if ((await c.pods(labelSelector: 'app.kubernetes.io/name=nico-api')).isNotEmpty) {
        found.add(ClusterRole.nico);
      }

      // One discovery call answers "is k0rdent here" and "is KubeVirt here"
      // together. Not swallowed: a discovery call that fails used to read as
      // an empty map, and an empty map is a claim. A probe that cannot
      // finish has not answered.
      _apiGroups = await c.apiGroups();

      _k0rdent = await c.k0rdentFingerprint(_apiGroups);
      switch (_k0rdent.role) {
        case K0rdentRole.management:
          found.add(ClusterRole.k0rdent);
        case K0rdentRole.managed:
          found.add(ClusterRole.managed);
        case null:
          break;
      }
      if (c.kubeVirtVersion(_apiGroups) != null) found.add(ClusterRole.kubevirt);

      // Summed across nodes rather than reported per node: what decides
      // whether a VM can be placed is how many cards the cluster has.
      final gpus = <String, int>{};
      for (final node in nodes) {
        for (final gpu in node.gpuResources) {
          gpus[gpu.name] = (gpus[gpu.name] ?? 0) + gpu.count;
        }
      }
      _gpuDevices = [for (final e in gpus.entries) e.value > 1 ? '${e.key} ×${e.value}' : e.key]..sort();
      if (gpus.isNotEmpty) found.add(ClusterRole.gpu);

      _roles = found;
    } catch (e) {
      _reach = Unreachable(explain(e, words: words));
      // Everything probing derived stays as last known, together. The reach
      // says the cluster cannot be read now; the roles, the fingerprint and
      // the groups say what it was when it could.
      _tmmPods = const [];
    }
    _probeGeneration++;
    notify();
  }

  /// A socket error says almost nothing useful on its own. Three cases
  /// actually happen here, and each has a different fix: a kubeconfig
  /// pointing somewhere this device cannot route, a certificate the device
  /// will not accept, and the OS refusing this app the local network.
  static String explain(Object error, {DeviceWords words = DeviceWords.generic}) {
    if (error is UnusableFailure) return error.why;
    if (error is HandshakeException || error is CertificateException || error is TlsException) {
      return 'the TLS handshake failed — check the certificate authority in the kubeconfig';
    }
    if (error is TimeoutException) return 'no route to this address from ${words.thisDevice}';
    if (error is SocketException) {
      final host = error.address?.host ?? '';
      // A Local Network denial on iOS and macOS arrives as the OS refusing
      // the connection outright. Every cluster this app is pointed at is on
      // a local subnet, so when the address is one only the local network
      // can reach and the OS said "not permitted", the permission is much
      // the likelier reading, and unlike "no route" it names its own fix.
      final message = error.osError?.message.toLowerCase() ?? '';
      if (host.isNotEmpty && Net.isLocal(host) && message.contains('not permitted')) {
        return '${words.thisDevice} is refusing this app the local network — '
            'switch bnkscope Field on under ${words.localNetworkSetting}';
      }
      // macOS answers a Local Network denial with "No route to host", the
      // same words as a genuinely unroutable address. Say both, because
      // the reader can only fix one of them from here.
      if (host.isNotEmpty && Net.isLocal(host) && message.contains('no route to host')) {
        return 'no route to this local address from ${words.thisDevice}. If it is on the same network, '
            '${words.thisDevice} may be refusing this app the local network: '
            'switch bnkscope Field on under ${words.localNetworkSetting}';
      }
      return 'no route to this address from ${words.thisDevice}';
    }
    return error.toString();
  }
}

/// Every cluster the app holds, and the kubeconfigs they came from.
///
/// Kubeconfigs live in [directory], one file per context; the app decides
/// where that is (application support, excluded from backup).
class ClusterStore extends Observable {
  final Directory directory;
  final DeviceWords words;

  List<ManagedCluster> _clusters = [];
  List<String> _files = [];
  String? _selected;
  String? _importError;

  /// Whether the selection was this store's guess rather than the user's
  /// pick. A guess is revisited once probing has answered; a pick is not.
  bool _selectionWasAutomatic = true;

  ClusterStore({required this.directory, this.words = DeviceWords.generic});

  List<ManagedCluster> get clusters => _clusters;
  List<String> get files => _files;
  String? get importError => _importError;

  String? get selected => _selected;
  set selected(String? id) {
    _selected = id;
    _selectionWasAutomatic = false;
    notify();
  }

  ManagedCluster? get current {
    for (final c in _clusters) {
      if (c.id == _selected) return c;
    }
    return null;
  }

  Future<void> load() async {
    for (final c in _clusters) {
      c.dispose();
    }
    _clusters = [];
    _files = [];
    await directory.create(recursive: true);
    var files = await _listFiles();
    var migrated = false;
    for (final f in files) {
      if (await _migrateMultiContext(f)) migrated = true;
    }
    if (migrated) files = await _listFiles();
    for (final f in files) {
      await _adopt(f);
    }
    _selectSomethingUseful();
    notify();
  }

  Future<List<File>> _listFiles() async {
    final out = <File>[];
    await for (final e in directory.list()) {
      if (e is File) out.add(e);
    }
    out.sort((a, b) => _basename(a).compareTo(_basename(b)));
    return out;
  }

  static String _basename(File f) => f.uri.pathSegments.last;

  /// Prefer a cluster that has something to show. Landing on a reachable
  /// cluster with no TMM pods reads as a fault when it is only a bad default.
  void _selectSomethingUseful() {
    if (_selected != null && current?.isUsable == true) return;
    ManagedCluster? pick;
    for (final c in _clusters) {
      if (c.roles.contains(ClusterRole.bnk)) {
        pick = c;
        break;
      }
    }
    pick ??= _clusters.where((c) => c.reach is Reachable).firstOrNull;
    pick ??= _clusters.where((c) => c.isUsable).firstOrNull;
    _selected = pick?.id;
    _selectionWasAutomatic = true;
  }

  /// Adopt the contexts of a kubeconfig's text, one file per context.
  ///
  /// Parsed before storing: a file that is not a kubeconfig should be
  /// refused at the picker, not discovered on the next launch. Split on the
  /// way in: after import a cluster is its own thing, and which file it
  /// arrived in stops mattering.
  Future<void> importKubeconfig(String text) async {
    _importError = null;
    try {
      Kubeconfig.parse(text);
      await directory.create(recursive: true);
      for (final part in Kubeconfig.split(text)) {
        final target = File('${directory.path}/${filenameFor(part.name)}');
        await target.writeAsString(part.yaml, flush: true);
        await _adopt(target);
      }
      _selectSomethingUseful();
    } catch (e) {
      _importError = e.toString();
    }
    notify();
  }

  /// Forget one cluster. Each cluster owns its own file, so this takes that
  /// file and nothing else.
  Future<void> remove(ManagedCluster cluster) async {
    try {
      await File('${directory.path}/${cluster.sourceFile}').delete();
    } on IOException {
      // Already gone.
    }
    _clusters = _clusters.where((c) => c.id != cluster.id).toList();
    _files = _files.where((f) => f != cluster.sourceFile).toList();
    cluster.dispose();
    if (_selected != null && !_clusters.any((c) => c.id == _selected)) {
      _selected = null;
      _selectSomethingUseful();
    }
    notify();
  }

  /// The other clusters that came out of the same file. They stay.
  List<String> siblings(ManagedCluster cluster) => [
        for (final c in _clusters)
          if (c.sourceFile == cluster.sourceFile && c.id != cluster.id) c.displayName
      ];

  Future<void> probeAll() async {
    await Future.wait([for (final c in _clusters) if (c.isUsable) c.probe()]);
    // Roles are only known once probing has answered, so the default choice
    // is worth revisiting now. The default choice, and only that: a cluster
    // someone chose stays chosen.
    if (_selectionWasAutomatic) {
      _selected = null;
      _selectSomethingUseful();
    }
    notify();
  }

  static final _unsafe = RegExp(r'[^\p{L}\p{N}.-]', unicode: true);

  /// A file name that is one cluster's, and safe on disk.
  static String filenameFor(String context) => '${context.replaceAll(_unsafe, '-')}.kubeconfig';

  /// Anything imported before the split is still one file holding several
  /// clusters. Splitting it on load means an old install behaves like a new
  /// one rather than keeping the coupling for ever.
  Future<bool> _migrateMultiContext(File file) async {
    final List<({String name, String yaml})> parts;
    try {
      parts = Kubeconfig.split(await file.readAsString());
    } catch (_) {
      return false;
    }
    if (parts.length <= 1) return false;
    for (final part in parts) {
      await File('${directory.path}/${filenameFor(part.name)}').writeAsString(part.yaml, flush: true);
    }
    await file.delete();
    return true;
  }

  Future<void> _adopt(File file) async {
    final Kubeconfig config;
    try {
      config = Kubeconfig.parse(await file.readAsString());
    } catch (_) {
      return;
    }
    final name = _basename(file);
    if (!_files.contains(name)) _files.add(name);
    for (final context in config.contexts) {
      if (_clusters.any((c) => c.id == context.name)) continue;
      final cluster = ManagedCluster(context: context, sourceFile: name, words: words);
      cluster.changes.listen((_) => notify());
      _clusters.add(cluster);
    }
  }

  @override
  void dispose() {
    for (final c in _clusters) {
      c.dispose();
    }
    super.dispose();
  }
}
