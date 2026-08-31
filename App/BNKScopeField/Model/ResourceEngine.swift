import Foundation
import Observation
import BNKKit

/// Lists objects of one kind, and holds what a detail view needs.
@Observable
@MainActor
final class ResourceEngine {
    private(set) var objects: [RawObject] = []
    private(set) var namespaces: [String] = []
    private(set) var loading = false
    private(set) var failure: String?

    var kind: ResourceKind = ResourceKind.all[0]
    var namespace: String?
    var query = ""

    private(set) var events: [K8s.Event] = []
    private(set) var loadingEvents = false

    var visible: [RawObject] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return objects }
        return objects.filter {
            $0.name.lowercased().contains(needle) || ($0.namespace ?? "").lowercased().contains(needle)
        }
    }

    func loadNamespaces(_ cluster: ManagedCluster) async {
        guard let client = try? cluster.client() else { return }
        namespaces = (try? await client.namespaces()) ?? []
    }

    func load(_ cluster: ManagedCluster) async {
        guard let client = try? cluster.client() else { return }
        loading = true
        failure = nil
        do {
            objects = try await client.list(kind, namespace: kind.namespaced ? namespace : nil)
                .sorted { ($0.namespace ?? "", $0.name) < ($1.namespace ?? "", $1.name) }
        } catch {
            objects = []
            failure = TelemetryEngine.brief(error)
        }
        loading = false
    }

    /// What has been said about one object.
    ///
    /// The reason to open a pod at all is usually that something is wrong with
    /// it, and the events are where the cluster says what.
    func loadEvents(for object: RawObject, cluster: ManagedCluster) async {
        events = []
        guard let namespace = object.namespace, let client = try? cluster.client() else { return }
        loadingEvents = true
        events = (try? await client.events(about: object.name, namespace: namespace)) ?? []
        loadingEvents = false
    }
}

/// The one-line summary a row shows, per kind.
///
/// Written per kind rather than generically because a useful summary is
/// different every time: a pod's is its readiness, a service's is its address, a
/// node's is its version.
enum ResourceSummary {
    static func line(for object: RawObject, kind: ResourceKind) -> (text: String, tone: SummaryTone) {
        switch kind.plural {
        case "pods":
            let statuses = object.array("status", "containerStatuses")
            let ready = statuses.filter { ($0["ready"] as? Bool) == true }.count
            let restarts = statuses.compactMap { ($0["restartCount"] as? NSNumber)?.intValue }.max() ?? 0
            let phase = object.string("status", "phase") ?? "?"
            let node = object.string("spec", "nodeName") ?? "—"
            let text = "\(ready)/\(statuses.count) ready · \(phase)"
                + (restarts > 0 ? " · \(restarts) restarts" : "") + " · \(node)"
            let healthy = phase == "Running" && ready == statuses.count && !statuses.isEmpty
            return (text, phase == "Succeeded" ? .neutral : (healthy ? .good : .bad))

        case "deployments", "statefulsets":
            let ready = object.int("status", "readyReplicas") ?? 0
            let wanted = object.int("spec", "replicas") ?? 0
            return ("\(ready)/\(wanted) ready", ready == wanted ? .good : .bad)

        case "daemonsets":
            let ready = object.int("status", "numberReady") ?? 0
            let wanted = object.int("status", "desiredNumberScheduled") ?? 0
            return ("\(ready)/\(wanted) ready", ready == wanted ? .good : .bad)

        case "services":
            let type = object.string("spec", "type") ?? "ClusterIP"
            let ip = object.string("spec", "clusterIP") ?? "—"
            let ports = object.array("spec", "ports")
                .compactMap { ($0["port"] as? NSNumber)?.stringValue }.joined(separator: ",")
            return ("\(type) · \(ip)\(ports.isEmpty ? "" : " · \(ports)")", .neutral)

        case "configmaps":
            let keys = (object.json["data"] as? [String: Any])?.count ?? 0
            return ("\(keys) key\(keys == 1 ? "" : "s")", .neutral)

        case "events":
            let type = object.string("type") ?? "?"
            let reason = object.string("reason") ?? ""
            let about = object.string("involvedObject", "name") ?? ""
            return ("\(reason) · \(about)", type == "Warning" ? .bad : .neutral)

        case "nodes":
            let conditions = object.array("status", "conditions")
            let ready = conditions.contains { ($0["type"] as? String) == "Ready" && ($0["status"] as? String) == "True" }
            let version = object.string("status", "nodeInfo", "kubeletVersion") ?? "?"
            let arch = object.string("status", "nodeInfo", "architecture") ?? ""
            return ("\(ready ? "Ready" : "NotReady") · \(version) · \(arch)", ready ? .good : .bad)

        default:
            return ("", .neutral)
        }
    }
}

enum SummaryTone { case good, bad, neutral }
