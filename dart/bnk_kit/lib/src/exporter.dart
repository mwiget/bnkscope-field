import 'dart:convert';

import 'k8s_types.dart';
import 'kube_client.dart';

/// Where the exporter is in a pod, if it is there at all.
sealed class Installation {
  const Installation();
}

/// In the pod template. Survives a restart, and is not ours to remove: the
/// pod would come back carrying it.
class PermanentInstallation extends Installation {
  final String? owner;
  const PermanentInstallation({this.owner});
}

/// Attached to a running pod. Cannot be removed in place; clearing it means
/// recreating the pod.
class EphemeralInstallation extends Installation {
  const EphemeralInstallation();
}

class AbsentInstallation extends Installation {
  const AbsentInstallation();
}

class ExporterOutcome {
  final List<String> changed = [];
  final List<String> skipped = [];
  final List<({String pod, String reason})> failed = [];
}

/// Putting the TMM exporter into a pod, and taking it out again.
///
/// The container spec is fixed here and is not a parameter. Accepting an
/// image would turn this into "run a container of your choosing inside TMM's
/// pod with its tmstat segment mounted", which is a different and much larger
/// thing to offer than a telemetry button.
///
/// Injection is ephemeral-only. The alternatives, patching the workload or a
/// mutating admission webhook, both restart TMM, and the webhook additionally
/// installs a cluster-scoped configuration with a long-lived CA. Neither
/// belongs behind a button in a troubleshooting tool.
class Exporter {
  static const containerName = 'tmm-stat-exporter';

  /// Pinned, and not a parameter. `:latest` rather than a version of this
  /// app: deriving the tag from a build that has not been released yet would
  /// inject a tag that does not exist, and an ImagePullBackOff inside TMM's
  /// pod is a poor way to find that out.
  static const image = 'ghcr.io/mwiget/bnkscope-tmm-stat-exporter:latest';

  /// tmm's own pod names these; the exporter reads the first read-only and,
  /// when the pod declares the second, uses it to read iRule token counters
  /// out of DSSM.
  static const tmstatVolume = 'f5tmstat';
  static const dssmVolume = 'tls-tmm-mds-clt-volume';

  /// The image the exporter in this pod is actually running.
  ///
  /// Not the same thing as [image], which is only what this app would
  /// install. On a cluster built with tmmscope the running one is a different
  /// repository, and showing the pinned name beside a pod running something
  /// else is a quiet lie.
  static String? runningImage(Pod pod) {
    final declared = [
      ...pod.spec?.containers ?? const <PodContainer>[],
      ...pod.spec?.ephemeralContainers ?? const <PodContainer>[],
    ];
    for (final c in declared) {
      if (c.name == containerName) return c.image;
    }
    return null;
  }

  static Installation installation(Pod pod) {
    if ((pod.spec?.containers ?? const []).any((c) => c.name == containerName)) {
      return const PermanentInstallation();
    }
    if ((pod.spec?.ephemeralContainers ?? const [])
        .any((c) => c.name == containerName)) {
      return const EphemeralInstallation();
    }
    return const AbsentInstallation();
  }

  /// The workload whose template carries a permanent sidecar.
  ///
  /// "Remove it where it is defined" is only an instruction if something says
  /// where that is, and it is never this app. A Deployment's pod is owned by
  /// a ReplicaSet, which is generated and not what anyone edits, so that hop
  /// is resolved; DaemonSets and StatefulSets own their pods.
  static Future<String?> owner(Pod pod, KubeClient client) async {
    final refs = pod.metadata.ownerReferences ?? const [];
    final ref = refs.where((r) => r.controller == true).firstOrNull ?? refs.firstOrNull;
    if (ref == null) return null;
    final namespace = pod.metadata.namespace;
    if (ref.kind != 'ReplicaSet' || namespace == null) {
      return '${ref.kind} ${ref.name}';
    }
    try {
      final rs = await client.getJson(
          '/apis/apps/v1/namespaces/$namespace/replicasets/${ref.name}',
          ReplicaSet.fromJson);
      final parent = (rs.metadata.ownerReferences ?? const [])
          .where((r) => r.controller == true)
          .firstOrNull;
      if (parent == null) return '${ref.kind} ${ref.name}';
      return '${parent.kind} ${parent.name}';
    } catch (_) {
      // The ReplicaSet name still locates the workload well enough to act on.
      return '${ref.kind} ${ref.name}';
    }
  }

  /// Identical to a permanent sidecar except for `resources`, which the
  /// ephemeralcontainers subresource rejects, so it runs with no cpu or
  /// memory limit here.
  ///
  /// No readiness or liveness probe, deliberately: TMM hooks inbound TCP on
  /// its dataplane interfaces, so a kubelet probe to the pod IP could not
  /// reach the sidecar and would wrongly mark the whole tmm pod NotReady.
  /// Telemetry must not gate tmm readiness.
  ///
  /// No `TMSTAT_REMOTE_WRITE_URL`. With it empty the exporter serves
  /// `/metrics` and pushes nowhere, and `/metrics` is exactly what Field
  /// reads, through the apiserver.
  static Map<String, Object> container(
      {required String clusterLabel, required bool dssmCert}) {
    final mounts = <Map<String, Object>>[
      {'name': tmstatVolume, 'mountPath': '/var/tmstat', 'readOnly': true},
      if (dssmCert)
        {'name': dssmVolume, 'mountPath': '/tls/tmm/mds/clt', 'readOnly': true},
    ];
    return {
      'name': containerName,
      'image': image,
      'imagePullPolicy': 'IfNotPresent',
      'env': [
        {'name': 'POD_NAME', 'valueFrom': {'fieldRef': {'fieldPath': 'metadata.name'}}},
        {'name': 'NODE_NAME', 'valueFrom': {'fieldRef': {'fieldPath': 'spec.nodeName'}}},
        {
          'name': 'TMSTAT_EXTERNAL_LABELS',
          'value': 'cluster=$clusterLabel,pod=\$(POD_NAME),node=\$(NODE_NAME)',
        },
      ],
      // Reads a shared segment read-only and serves one port. It needs
      // nothing else, so it is given nothing else.
      'securityContext': {
        'runAsUser': 65532,
        'runAsGroup': 65532,
        'runAsNonRoot': true,
        'readOnlyRootFilesystem': true,
        'allowPrivilegeEscalation': false,
        'capabilities': {'drop': ['ALL']},
      },
      'volumeMounts': mounts,
    };
  }

  /// Add the exporter to every pod that does not have one.
  ///
  /// [dryRun] asks the apiserver to validate and discard. It is how the
  /// injection can be checked against a real cluster without injecting: every
  /// admission plugin runs, the container spec is validated, and nothing is
  /// written.
  static Future<ExporterOutcome> install(List<Pod> pods,
      {required String clusterLabel,
      required KubeClient client,
      bool dryRun = false}) async {
    final outcome = ExporterOutcome();
    for (final pod in pods) {
      final namespace = pod.metadata.namespace;
      if (namespace == null) continue;
      if (!dryRun && installation(pod) is! AbsentInstallation) {
        outcome.skipped.add(pod.metadata.name);
        continue;
      }
      final dssm = (pod.spec?.volumes ?? const []).any((v) => v.name == dssmVolume);
      final patch = {
        'spec': {
          'ephemeralContainers': [
            container(clusterLabel: clusterLabel, dssmCert: dssm)
          ]
        }
      };
      try {
        await client.send(
          'PATCH',
          '/api/v1/namespaces/$namespace/pods/${pod.metadata.name}/ephemeralcontainers',
          query: dryRun ? const {'dryRun': 'All'} : const {},
          body: utf8.encode(jsonEncode(patch)),
          contentType: 'application/strategic-merge-patch+json',
        );
        outcome.changed.add(pod.metadata.name);
      } catch (e) {
        outcome.failed.add((pod: pod.metadata.name, reason: '$e'));
      }
    }
    return outcome;
  }

  /// Clear an ephemeral injection by recreating the pods that carry it.
  ///
  /// **This drops dataplane traffic.** An ephemeral container cannot be taken
  /// out of a running pod; recreating it is the only way, and the pod comes
  /// back clean because the exporter was never part of the template.
  ///
  /// A permanent sidecar is refused rather than attempted. Deleting the pod
  /// would drop traffic and the exporter would come straight back with the
  /// replacement: all cost, no effect.
  static Future<ExporterOutcome> remove(List<Pod> pods,
      {required KubeClient client}) async {
    final outcome = ExporterOutcome();
    for (final pod in pods) {
      final namespace = pod.metadata.namespace;
      if (namespace == null) continue;
      switch (installation(pod)) {
        case AbsentInstallation():
          outcome.skipped.add(pod.metadata.name);
        case PermanentInstallation():
          final owner = await Exporter.owner(pod, client);
          outcome.failed.add((
            pod: pod.metadata.name,
            reason: "the exporter is in this pod's template${owner == null ? '' : ' — remove it in $owner'}",
          ));
        case EphemeralInstallation():
          try {
            await client.send('DELETE',
                '/api/v1/namespaces/$namespace/pods/${pod.metadata.name}');
            outcome.changed.add(pod.metadata.name);
          } catch (e) {
            outcome.failed.add((pod: pod.metadata.name, reason: '$e'));
          }
      }
    }
    return outcome;
  }
}
