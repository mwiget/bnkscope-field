import Foundation

/// Putting the TMM exporter into a pod, and taking it out again.
///
/// The container spec is fixed here and is not a parameter. Accepting an image
/// would turn this into "run a container of your choosing inside TMM's pod with
/// its tmstat segment mounted", which is a different and much larger thing to
/// offer than a telemetry button.
///
/// Injection is ephemeral-only. The alternatives — patching the workload, or a
/// mutating admission webhook — both restart TMM, and the webhook additionally
/// installs a cluster-scoped configuration with a long-lived CA. Neither belongs
/// behind a button in a troubleshooting tool.
public enum Exporter {
    public static let containerName = "tmm-stat-exporter"

    /// Pinned, and not a parameter.
    ///
    /// `:latest` rather than a version of this app: deriving the tag from a
    /// build that has not been released yet would inject a tag that does not
    /// exist, and an ImagePullBackOff inside TMM's pod is a poor way to find
    /// that out. What the two share is the exposition format, which is
    /// Prometheus's, not ours.
    public static let image = "ghcr.io/mwiget/bnkscope-tmm-stat-exporter:latest"

    /// tmm's own pod names these; the exporter reads the first read-only and,
    /// when the pod declares the second, uses it to read iRule token counters
    /// out of DSSM.
    static let tmstatVolume = "f5tmstat"
    static let dssmVolume = "tls-tmm-mds-clt-volume"

    // MARK: - What is already there

    public enum Installation: Equatable, Sendable {
        /// In the pod template. Survives a restart, and is not ours to remove:
        /// the pod would come back carrying it.
        case permanent(owner: String?)
        /// Attached to a running pod. Cannot be removed in place — clearing it
        /// means recreating the pod.
        case ephemeral
        case absent
    }

    /// A pod can carry both, if someone injected over a cluster that already had
    /// the sidecar in its template. The permanent one is the durable fact and
    /// the one that decides what removal can achieve.
    /// The image the exporter in this pod is actually running.
    ///
    /// Not the same thing as `Exporter.image`, which is only what this app would
    /// install. On a cluster built with tmmscope the running one is
    /// `ghcr.io/mwiget/tmm-stat-exporter` — a different repository — and showing
    /// the pinned name beside a pod running something else is a quiet lie.
    public static func runningImage(in pod: K8s.Pod) -> String? {
        let declared = (pod.spec?.containers ?? []) + (pod.spec?.ephemeralContainers ?? [])
        return declared.first { $0.name == containerName }?.image
    }

    public static func installation(in pod: K8s.Pod) -> Installation {
        if (pod.spec?.containers ?? []).contains(where: { $0.name == containerName }) {
            return .permanent(owner: nil)
        }
        if (pod.spec?.ephemeralContainers ?? []).contains(where: { $0.name == containerName }) {
            return .ephemeral
        }
        return .absent
    }

    /// The workload whose template carries a permanent sidecar.
    ///
    /// "Remove it where it is defined" is only an instruction if something says
    /// where that is, and it is never this app: a permanent exporter comes from
    /// the cluster build or from DPF's own service templates. A Deployment's pod
    /// is owned by a ReplicaSet, which is generated and not what anyone edits,
    /// so that hop is resolved; DaemonSets and StatefulSets own their pods.
    public static func owner(of pod: K8s.Pod, using client: KubeClient) async -> String? {
        let refs = pod.metadata.ownerReferences ?? []
        guard let ref = refs.first(where: { $0.controller == true }) ?? refs.first else { return nil }
        guard ref.kind == "ReplicaSet", let namespace = pod.metadata.namespace else {
            return "\(ref.kind) \(ref.name)"
        }
        guard let rs = try? await client.getJSON(
            K8s.ReplicaSet.self, "/apis/apps/v1/namespaces/\(namespace)/replicasets/\(ref.name)"),
              let parent = (rs.metadata.ownerReferences ?? []).first(where: { $0.controller == true })
        else {
            // The ReplicaSet name still locates the workload well enough to act on.
            return "\(ref.kind) \(ref.name)"
        }
        return "\(parent.kind) \(parent.name)"
    }

    // MARK: - The container

    /// Identical to a permanent sidecar except for `resources`, which the
    /// ephemeralcontainers subresource rejects — so it runs with no cpu or
    /// memory limit here.
    ///
    /// No readiness or liveness probe, deliberately: TMM hooks inbound TCP on
    /// its dataplane interfaces, so a kubelet probe to the pod IP could not
    /// reach the sidecar and would wrongly mark the whole tmm pod NotReady.
    /// Telemetry must not gate tmm readiness.
    ///
    /// No `TMSTAT_REMOTE_WRITE_URL`, which is where this differs from the
    /// desktop build. With it empty the exporter serves `/metrics` and pushes
    /// nowhere — and `/metrics` is exactly what Field reads, through the
    /// apiserver. There is no Prometheus to point at and no host address to
    /// guess, so the heuristic that guesses one is not needed either.
    public static func container(clusterLabel: String, dssmCert: Bool) -> [String: Any] {
        var mounts: [[String: Any]] = [
            ["name": tmstatVolume, "mountPath": "/var/tmstat", "readOnly": true],
        ]
        if dssmCert {
            mounts.append(["name": dssmVolume, "mountPath": "/tls/tmm/mds/clt", "readOnly": true])
        }
        return [
            "name": containerName,
            "image": image,
            "imagePullPolicy": "IfNotPresent",
            "env": [
                ["name": "POD_NAME", "valueFrom": ["fieldRef": ["fieldPath": "metadata.name"]]],
                ["name": "NODE_NAME", "valueFrom": ["fieldRef": ["fieldPath": "spec.nodeName"]]],
                ["name": "TMSTAT_EXTERNAL_LABELS",
                 "value": "cluster=\(clusterLabel),pod=$(POD_NAME),node=$(NODE_NAME)"],
            ],
            // Reads a shared segment read-only and serves one port. It needs
            // nothing else, so it is given nothing else.
            "securityContext": [
                "runAsUser": 65532,
                "runAsGroup": 65532,
                "runAsNonRoot": true,
                "readOnlyRootFilesystem": true,
                "allowPrivilegeEscalation": false,
                "capabilities": ["drop": ["ALL"]],
            ],
            "volumeMounts": mounts,
        ]
    }

    // MARK: - Acting

    public struct Outcome: Sendable {
        public var changed: [String] = []
        public var skipped: [String] = []
        public var failed: [(pod: String, reason: String)] = []
    }

    /// Add the exporter to every pod that does not have one.
    /// `dryRun` asks the apiserver to validate and discard. It is how the
    /// injection can be checked against a real cluster without injecting: every
    /// admission plugin runs, the container spec is validated, and nothing is
    /// written.
    public static func install(into pods: [K8s.Pod], clusterLabel: String,
                               using client: KubeClient, dryRun: Bool = false) async -> Outcome {
        var outcome = Outcome()
        for pod in pods {
            guard let namespace = pod.metadata.namespace else { continue }
            guard dryRun || installation(in: pod) == .absent else {
                outcome.skipped.append(pod.metadata.name)
                continue
            }
            let dssm = (pod.spec?.volumes ?? []).contains { $0.name == dssmVolume }
            let patch: [String: Any] = [
                "spec": ["ephemeralContainers": [container(clusterLabel: clusterLabel, dssmCert: dssm)]]
            ]
            do {
                let body = try JSONSerialization.data(withJSONObject: patch)
                try await client.send(
                    "PATCH",
                    "/api/v1/namespaces/\(namespace)/pods/\(pod.metadata.name)/ephemeralcontainers",
                    query: dryRun ? ["dryRun": "All"] : [:],
                    body: body,
                    contentType: "application/strategic-merge-patch+json")
                outcome.changed.append(pod.metadata.name)
            } catch {
                outcome.failed.append((pod.metadata.name, String(describing: error)))
            }
        }
        return outcome
    }

    /// Clear an ephemeral injection by recreating the pods that carry it.
    ///
    /// **This drops dataplane traffic.** An ephemeral container cannot be taken
    /// out of a running pod; recreating it is the only way, and the pod comes
    /// back clean because the exporter was never part of the template.
    ///
    /// A permanent sidecar is refused rather than attempted. Deleting the pod
    /// would drop traffic and the exporter would come straight back with the
    /// replacement — all cost, no effect.
    public static func remove(from pods: [K8s.Pod], using client: KubeClient) async -> Outcome {
        var outcome = Outcome()
        for pod in pods {
            guard let namespace = pod.metadata.namespace else { continue }
            switch installation(in: pod) {
            case .absent:
                outcome.skipped.append(pod.metadata.name)
            case .permanent:
                let owner = await owner(of: pod, using: client)
                outcome.failed.append((pod.metadata.name,
                    "the exporter is in this pod's template" + (owner.map { " — remove it in \($0)" } ?? "")))
            case .ephemeral:
                do {
                    try await client.send("DELETE", "/api/v1/namespaces/\(namespace)/pods/\(pod.metadata.name)")
                    outcome.changed.append(pod.metadata.name)
                } catch {
                    outcome.failed.append((pod.metadata.name, String(describing: error)))
                }
            }
        }
        return outcome
    }
}
