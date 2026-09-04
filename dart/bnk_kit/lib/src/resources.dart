import 'dart:convert';

import 'json.dart';
import 'k8s_types.dart';
import 'kube_client.dart';
import 'time.dart';
import 'yaml_emit.dart';

/// An arbitrary Kubernetes object, as decoded JSON.
///
/// Deliberately untyped, unlike the rest of the models: those exist because
/// specific screens render specific fields, and a browser renders whatever is
/// there. So this carries the decoded JSON and pulls out only what a list row
/// needs.
class RawObject {
  final JsonMap json;
  final String name;
  final String? namespace;
  final DateTime? created;

  RawObject._(this.json, this.name, this.namespace, this.created);

  static RawObject? tryFrom(JsonMap json) {
    final metadata = asMap(json['metadata']);
    final name = metadata?['name'];
    if (metadata == null || name is! String) return null;
    final stamp = metadata['creationTimestamp'];
    return RawObject._(json, name, asString(metadata['namespace']),
        stamp is String ? Rfc3339.parse(stamp) : null);
  }

  String get id => '${namespace ?? '-'}/$name';

  String? string(List<String> path) => asString(_value(path));

  int? integer(List<String> path) => asInt(_value(path));

  List<JsonMap> array(List<String> path) => asList(_value(path), (m) => m);

  Object? _value(List<String> path) {
    Object? current = json;
    for (final key in path) {
      if (current is! Map) return null;
      current = current[key];
    }
    return current;
  }

  /// The object as YAML, which is the form anyone reading a spec expects.
  ///
  /// `managedFields` is dropped: it is server bookkeeping, routinely longer
  /// than the object itself, and nobody has ever wanted to read it on a
  /// tablet. Nulls are dropped too, as a YAML dump of the object would.
  String get yaml {
    final copy = _withoutNulls(json) as Map;
    final metadata = copy['metadata'];
    if (metadata is Map) metadata.remove('managedFields');
    return emitYaml(copy, sortKeys: true);
  }

  static Object? _withoutNulls(Object? value) {
    if (value is Map) {
      return <String, dynamic>{
        for (final e in value.entries)
          if (e.value != null) e.key.toString(): _withoutNulls(e.value)
      };
    }
    if (value is List) {
      return [for (final e in value) if (e != null) _withoutNulls(e)];
    }
    return value;
  }
}

/// A kind the browser can list.
class ResourceKind {
  final String name;
  final String plural;

  /// `api/v1` for the core group, `apis/<group>/<version>` for the rest.
  final String root;
  final bool namespaced;

  const ResourceKind(
      {required this.name,
      required this.plural,
      required this.root,
      required this.namespaced});

  String get id => '$root/$plural';

  String path(String? namespace) {
    if (!namespaced || namespace == null || namespace.isEmpty) {
      return '/$root/$plural';
    }
    return '/$root/namespaces/$namespace/$plural';
  }

  /// What the browser offers.
  ///
  /// Secrets are absent on purpose. Everything else here is safe to put on a
  /// screen; a Secret's whole content is its value, and a generic YAML view of
  /// one would put cluster credentials on a tablet in a coffee shop. The app
  /// reads the two secrets it genuinely needs by name, for certificate dates.
  /// Nodes lead deliberately: the first entry is what the screen opens on.
  static const all = [
    ResourceKind(name: 'Nodes', plural: 'nodes', root: 'api/v1', namespaced: false),
    ResourceKind(name: 'Pods', plural: 'pods', root: 'api/v1', namespaced: true),
    ResourceKind(name: 'Deployments', plural: 'deployments', root: 'apis/apps/v1', namespaced: true),
    ResourceKind(name: 'DaemonSets', plural: 'daemonsets', root: 'apis/apps/v1', namespaced: true),
    ResourceKind(name: 'StatefulSets', plural: 'statefulsets', root: 'apis/apps/v1', namespaced: true),
    ResourceKind(name: 'Services', plural: 'services', root: 'api/v1', namespaced: true),
    ResourceKind(name: 'ConfigMaps', plural: 'configmaps', root: 'api/v1', namespaced: true),
    ResourceKind(name: 'Events', plural: 'events', root: 'api/v1', namespaced: true),
  ];

  @override
  bool operator ==(Object other) => other is ResourceKind && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

extension ResourcesApi on KubeClient {
  /// Every object of a kind, as decoded JSON.
  Future<List<RawObject>> list(ResourceKind kind, {String? namespace}) async {
    final data = await get(kind.path(namespace));
    final root = jsonDecode(utf8.decode(data));
    final items = root is Map ? root['items'] : null;
    return [
      for (final item in asList(items, (m) => m))
        if (RawObject.tryFrom(item) case final object?) object
    ];
  }

  /// The events naming one object, newest first.
  Future<List<Event>> events(
      {required String about, required String namespace}) async {
    final items = await getJson('/api/v1/namespaces/$namespace/events',
        (j) => listItems(j, Event.fromJson),
        query: {'fieldSelector': 'involvedObject.name=$about'});
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    items.sort((a, b) => (b.at ?? epoch).compareTo(a.at ?? epoch));
    return items;
  }
}
