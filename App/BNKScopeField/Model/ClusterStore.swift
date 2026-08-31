import Foundation
import Observation
import BNKKit

/// A cluster as the app knows it: the kubeconfig context, plus whatever probing
/// it has learned.
@Observable
@MainActor
final class ManagedCluster: Identifiable {
    let context: Kubeconfig.Context
    let sourceFile: String

    /// `nonisolated` because the identity is the context name, which is a `let`
    /// fixed at init — SwiftUI reads it off the main actor while diffing lists,
    /// and nothing about it can race.
    nonisolated var id: String { context.name }

    /// What to call this cluster in the UI.
    ///
    /// Context names are written for kubectl, not for reading:
    /// `kubernetes-admin@dpu-cplane-tenant1` says one useful word and eleven
    /// that are the same on every context. The useful word is the cluster, so
    /// that is what is shown — unless the cluster is called something kubeadm
    /// picked, in which case the file it came from is a better clue than
    /// "kubernetes" is.
    nonisolated var displayName: String {
        let generic: Set<String> = ["kubernetes", "default", "cluster.local", "kind"]
        let afterAt = context.name.split(separator: "@").last.map(String.init)
        for candidate in [afterAt, context.clusterName].compactMap({ $0 }) {
            if !generic.contains(candidate) { return candidate }
        }
        let stem = sourceFile.replacingOccurrences(of: ".config", with: "")
                             .replacingOccurrences(of: ".yaml", with: "")
                             .replacingOccurrences(of: ".yml", with: "")
        return stem.isEmpty ? context.name : stem
    }

    enum Reach: Equatable {
        case unprobed
        case reachable(version: String, nodes: Int, ready: Int)
        case unreachable(String)
        case unusable(String)
    }

    var reach: Reach = .unprobed
    var roles: Set<Role> = []
    var tmmPods: [K8s.Pod] = []
    /// Bumped every time probing finishes.
    ///
    /// A screen that loads from what probing discovered cannot key its work on
    /// the cluster's identity alone: the first render happens before the probe
    /// answers, and selecting the same cluster again afterwards is not a change
    /// SwiftUI will notice. Keying on this makes "the facts changed" a distinct
    /// event from "the selection changed".
    private(set) var probeGeneration = 0

    enum Role: String, CaseIterable, Comparable {
        case bnk = "BNK", dpu = "DPU", nico = "NICo"
        static func < (a: Role, b: Role) -> Bool { a.rawValue < b.rawValue }
    }

    private var cached: KubeClient?
    private var probeInFlight: Task<Void, Never>?
    private var probeSerial = 0

    init(context: Kubeconfig.Context, sourceFile: String) {
        self.context = context
        self.sourceFile = sourceFile
        if case .unsupported(let why) = context.auth { reach = .unusable(why) }
    }

    func client() throws -> KubeClient {
        if let cached { return cached }
        let c = try KubeClient(context: context, tag: "bnkscope.field.\(context.name)")
        cached = c
        return c
    }

    var isUsable: Bool {
        if case .unusable = reach { return false }
        return true
    }

    /// Ask the cluster what it is.
    ///
    /// Roles are read from pod labels rather than namespace names, because on a
    /// real deployment these live on different clusters and the namespaces vary
    /// by install shape — the same reason bnkscope detects them this way.
    /// Probe, or join the probe already running.
    ///
    /// Two callers ask for this concurrently — the store probes everything at
    /// launch while a screen probes the cluster it needs — and two probes
    /// interleaving on one cluster left it reporting "no route from this iPad"
    /// while its data sat on the screen beside the message.
    func probe() async {
        if let probeInFlight {
            await probeInFlight.value
            return
        }
        await runProbe()
    }

    /// Probe for a caller that has just changed the cluster.
    ///
    /// Joining an in-flight probe is wrong here. That probe listed the pods
    /// before the change landed, so adopting its answer shows the cluster as it
    /// was a moment ago: an exporter this app just installed reads as still
    /// missing, the overview keeps warning about it, and nothing starts
    /// scraping the pod it was added to.
    func probeReflectingChange() async {
        if let probeInFlight { await probeInFlight.value }
        await runProbe()
    }

    private func runProbe() async {
        probeSerial += 1
        let mine = probeSerial
        let task = Task { await performProbe() }
        probeInFlight = task
        await task.value
        // Only retire the handle if it is still ours — a caller that waited on
        // us has since installed its own, and clearing that one would let a
        // third caller start a duplicate probe.
        if probeSerial == mine { probeInFlight = nil }
    }

    private func performProbe() async {
        guard isUsable else { return }
        do {
            let c = try client()
            let version = try await c.version()
            let nodes = try await c.nodes()
            reach = .reachable(version: version.gitVersion,
                               nodes: nodes.count,
                               ready: nodes.filter(\.isReady).count)

            var found: Set<Role> = []
            let tmm = try await c.pods(labelSelector: "app=f5-tmm")
            if !tmm.isEmpty { found.insert(.bnk) }
            tmmPods = tmm
            // A svc.dpu.nvidia.com/ label means the workload is wired through
            // the DPU service API. It does NOT mean the DPF operator is here —
            // that is a different API group, and on this lab it is installed on
            // neither reachable cluster. The badge used to say DPF and was
            // pointing at something true under the wrong name.
            if tmm.contains(where: { ($0.metadata.labels ?? [:]).keys.contains { $0.hasPrefix("svc.dpu.nvidia.com/") } }) {
                found.insert(.dpu)
            }
            if try await !c.pods(labelSelector: "app.kubernetes.io/name=nico-api").isEmpty {
                found.insert(.nico)
            }
            roles = found
        } catch {
            reach = .unreachable(Self.explain(error))
            tmmPods = []
        }
        probeGeneration += 1
    }

    /// A URLError says almost nothing useful on its own. The two cases that
    /// actually happen here are worth naming, because the fix differs: a
    /// kubeconfig pointing somewhere this device cannot route, versus a
    /// certificate the device will not accept.
    static func explain(_ error: Error) -> String {
        guard let url = error as? URLError else { return String(describing: error) }
        switch url.code {
        case .cannotConnectToHost, .timedOut, .networkConnectionLost:
            return "no route to this address from the iPad"
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return "the TLS handshake failed — check the certificate authority in the kubeconfig"
        default:
            return url.localizedDescription
        }
    }
}

/// Every cluster the app holds, and the kubeconfigs they came from.
@Observable
@MainActor
final class ClusterStore {
    private(set) var clusters: [ManagedCluster] = []
    private(set) var files: [String] = []
    var selected: ManagedCluster.ID?
    var importError: String?

    /// Kubeconfigs live in Application Support, excluded from backup. The
    /// certificates inside them are also imported into the keychain, which is
    /// what actually gets used; this copy is what lets the app rebuild that
    /// after a reinstall without asking for the file again.
    private static var directory: URL {
        let base = URL.applicationSupportDirectory.appending(path: "kubeconfigs")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func load() {
        clusters.removeAll()
        files.removeAll()
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.directory,
                                                                 includingPropertiesForKeys: nil)) ?? []
        var files = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if files.contains(where: { migrateMultiContext($0) }) {
            files = ((try? FileManager.default.contentsOfDirectory(
                at: Self.directory, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        for url in files { adopt(url) }
        selectSomethingUseful()
    }

    /// Prefer a cluster that has something to show. Landing on a reachable
    /// cluster with no TMM pods and the message "looking for TMM pods" reads as
    /// a fault when it is only a bad default.
    private func selectSomethingUseful() {
        guard selected == nil || current?.isUsable != true else { return }
        selected = clusters.first { $0.roles.contains(.bnk) }?.id
            ?? clusters.first { if case .reachable = $0.reach { return true } else { return false } }?.id
            ?? clusters.first(where: \.isUsable)?.id
    }

    /// Copy an imported file in and adopt its contexts.
    func importKubeconfig(from source: URL, named name: String? = nil) {
        importError = nil
        let needsScope = source.startAccessingSecurityScopedResource()
        defer { if needsScope { source.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: source)
            // Parse before storing: a file that is not a kubeconfig should be
            // refused at the picker, not discovered on the next launch.
            _ = try Kubeconfig(yaml: String(decoding: data, as: UTF8.self))
            // Split on the way in: after import a cluster is its own thing, and
            // which file it arrived in stops mattering.
            for (name, text) in try Kubeconfig.split(yaml: String(decoding: data, as: UTF8.self)) {
                let target = Self.directory.appending(path: Self.filename(for: name))
                try text.write(to: target, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.complete], ofItemAtPath: target.path)
                adopt(target)
            }
            selectSomethingUseful()
        } catch {
            importError = String(describing: error)
        }
    }

    /// Forget one cluster.
    ///
    /// Each cluster owns its own file, so this takes that file and nothing
    /// else. Removal used to be per FILE, which on a kubeconfig holding three
    /// contexts meant removing one dead cluster took the two working ones with
    /// it.
    func remove(_ cluster: ManagedCluster) {
        if case .clientCertificate(let certPEM, _) = cluster.context.auth {
            Identity.forget(tag: "bnkscope.field.\(cluster.context.name)", certPEM: certPEM)
        }
        try? FileManager.default.removeItem(at: Self.directory.appending(path: cluster.sourceFile))
        clusters.removeAll { $0.id == cluster.id }
        files.removeAll { $0 == cluster.sourceFile }
        if let selected, !clusters.contains(where: { $0.id == selected }) {
            self.selected = nil
            selectSomethingUseful()
        }
    }

    /// The other clusters that came out of the same file. They stay.
    func siblings(of cluster: ManagedCluster) -> [String] {
        clusters.filter { $0.sourceFile == cluster.sourceFile && $0.id != cluster.id }
            .map(\.displayName)
    }

    func probeAll() async {
        await withTaskGroup(of: Void.self) { group in
            for cluster in clusters where cluster.isUsable {
                group.addTask { await cluster.probe() }
            }
        }
        // Roles are only known once probing has answered, so the default choice
        // is worth revisiting now rather than at load.
        selected = nil
        selectSomethingUseful()
    }

    var current: ManagedCluster? {
        clusters.first { $0.id == selected }
    }

    /// A file name that is one cluster's, and safe on disk.
    static func filename(for context: String) -> String {
        let safe = context.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "-" }
        return String(safe) + ".kubeconfig"
    }

    /// Anything imported before the split is still one file holding several
    /// clusters. Splitting it on load means an old install behaves like a new
    /// one rather than keeping the coupling for ever.
    private func migrateMultiContext(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let parts = try? Kubeconfig.split(yaml: text), parts.count > 1 else { return false }
        for (name, part) in parts {
            let target = Self.directory.appending(path: Self.filename(for: name))
            try? part.write(to: target, atomically: true, encoding: .utf8)
        }
        try? FileManager.default.removeItem(at: url)
        return true
    }

    private func adopt(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let config = try? Kubeconfig(yaml: text) else { return }
        files.append(url.lastPathComponent)
        for context in config.contexts where !clusters.contains(where: { $0.id == context.name }) {
            clusters.append(ManagedCluster(context: context, sourceFile: url.lastPathComponent))
        }
    }
}
