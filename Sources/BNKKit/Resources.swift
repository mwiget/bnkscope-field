import Foundation
import Yams

/// Browsing arbitrary Kubernetes objects.
///
/// Deliberately untyped, unlike the rest of `K8s`: the typed models exist
/// because specific screens render specific fields, and a browser renders
/// whatever is there. So these carry the decoded JSON and pull out only what a
/// list row needs.
/// `@unchecked` because the payload is a JSON dictionary of `Any`, which Swift
/// cannot prove Sendable. It is produced once by `JSONSerialization`, never
/// mutated, and only read — the guarantee holds by construction.
public struct RawObject: Identifiable, @unchecked Sendable {
    public let json: [String: Any]
    public let name: String
    public let namespace: String?
    public let created: Date?

    public var id: String { "\(namespace ?? "-")/\(name)" }

    public init?(_ json: [String: Any]) {
        guard let metadata = json["metadata"] as? [String: Any],
              let name = metadata["name"] as? String else { return nil }
        self.json = json
        self.name = name
        self.namespace = metadata["namespace"] as? String
        self.created = (metadata["creationTimestamp"] as? String)
            .flatMap { KubeClient.rfc3339.date(from: $0) }
    }

    public func string(_ path: String...) -> String? {
        value(path) as? String
    }

    public func int(_ path: String...) -> Int? {
        (value(path) as? NSNumber)?.intValue
    }

    public func array(_ path: String...) -> [[String: Any]] {
        value(path) as? [[String: Any]] ?? []
    }

    private func value(_ path: [String]) -> Any? {
        var current: Any? = json
        for key in path {
            guard let dictionary = current as? [String: Any] else { return nil }
            current = dictionary[key]
        }
        return current
    }

    /// The object as YAML, which is the form anyone reading a spec expects.
    ///
    /// `managedFields` is dropped: it is server bookkeeping, routinely longer
    /// than the object itself, and nobody has ever wanted to read it on a
    /// tablet.
    public var yaml: String {
        var copy = json
        if var metadata = copy["metadata"] as? [String: Any] {
            metadata.removeValue(forKey: "managedFields")
            copy["metadata"] = metadata
        }
        do {
            return try Yams.dump(object: RawObject.plain(copy) ?? [:], sortKeys: true)
        } catch {
            // Say why rather than "could not render", which is what the first
            // version did and taught nobody anything.
            return "could not render this object as YAML: \(error)"
        }
    }

    /// JSONSerialization hands back Foundation's bridged types — `NSNull` for
    /// null and `NSNumber` for every number and boolean — and Yams represents
    /// none of them. Converting to Swift's own types first is what makes the
    /// dump work at all.
    static func plain(_ value: Any) -> Any? {
        switch value {
        case is NSNull:
            return nil
        case let dictionary as [String: Any]:
            return dictionary.reduce(into: [String: Any]()) { out, pair in
                if let converted = plain(pair.value) { out[pair.key] = converted }
            }
        case let array as [Any]:
            return array.compactMap(plain)
        case let number as NSNumber:
            // A JSON true is an NSNumber that happens to be a CFBoolean, and
            // dumping it as 1 would change what the document says.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            if let exact = number as? Int, Double(exact) == number.doubleValue { return exact }
            return number.doubleValue
        case let string as String:
            return string
        default:
            return String(describing: value)
        }
    }
}

/// A kind the browser can list.
public struct ResourceKind: Identifiable, Hashable, Sendable {
    public let name: String
    public let plural: String
    /// `api/v1` for the core group, `apis/<group>/<version>` for the rest.
    public let root: String
    public let namespaced: Bool

    public var id: String { "\(root)/\(plural)" }

    public func path(namespace: String?) -> String {
        guard namespaced, let namespace, !namespace.isEmpty else { return "/\(root)/\(plural)" }
        return "/\(root)/namespaces/\(namespace)/\(plural)"
    }

    /// What the browser offers.
    ///
    /// Secrets are absent on purpose. Everything else here is safe to put on a
    /// screen; a Secret's whole content is its value, and a generic YAML view of
    /// one would put cluster credentials on a tablet in a coffee shop. The app
    /// reads the two secrets it genuinely needs by name, for certificate dates.
    public static let all: [ResourceKind] = [
        ResourceKind(name: "Pods", plural: "pods", root: "api/v1", namespaced: true),
        ResourceKind(name: "Deployments", plural: "deployments", root: "apis/apps/v1", namespaced: true),
        ResourceKind(name: "DaemonSets", plural: "daemonsets", root: "apis/apps/v1", namespaced: true),
        ResourceKind(name: "StatefulSets", plural: "statefulsets", root: "apis/apps/v1", namespaced: true),
        ResourceKind(name: "Services", plural: "services", root: "api/v1", namespaced: true),
        ResourceKind(name: "ConfigMaps", plural: "configmaps", root: "api/v1", namespaced: true),
        ResourceKind(name: "Events", plural: "events", root: "api/v1", namespaced: true),
        ResourceKind(name: "Nodes", plural: "nodes", root: "api/v1", namespaced: false),
    ]
}

extension KubeClient {
    /// Every object of a kind, as decoded JSON.
    public func list(_ kind: ResourceKind, namespace: String? = nil) async throws -> [RawObject] {
        let data = try await get(kind.path(namespace: namespace))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = root?["items"] as? [[String: Any]] ?? []
        return items.compactMap(RawObject.init)
    }

    /// The events naming one object, newest first.
    public func events(about name: String, namespace: String) async throws -> [K8s.Event] {
        try await getJSON(K8s.List<K8s.Event>.self, "/api/v1/namespaces/\(namespace)/events",
                          query: ["fieldSelector": "involvedObject.name=\(name)"])
            .items
            .sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }
    }
}
