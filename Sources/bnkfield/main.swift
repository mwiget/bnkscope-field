import Foundation
import BNKKit

// A command-line front end for BNKKit, so the transport can be exercised against
// real clusters from a Mac before any of it is behind a SwiftUI view. Everything
// it calls is the same code the app will run; only the presentation is throwaway.

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

let usage = """
usage: bnkfield <command>

  contexts <kubeconfig>
  probe    <kubeconfig> <context>
  pods     <kubeconfig> <context> [namespace] [labelSelector]
  scrape   <kubeconfig> <context> <namespace> <pod> [port]
"""

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(2) }
args.removeFirst()

func loadContext(_ path: String, _ name: String) throws -> Kubeconfig.Context {
    let cfg = try Kubeconfig(contentsOf: URL(fileURLWithPath: path))
    guard let ctx = cfg.context(named: name) else {
        die("no context \"\(name)\" — have: \(cfg.contexts.map(\.name).joined(separator: ", "))")
    }
    return ctx
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

switch command {

case "contexts":
    guard args.count == 1 else { die(usage) }
    let cfg = try Kubeconfig(contentsOf: URL(fileURLWithPath: args[0]))
    for c in cfg.contexts {
        let auth: String
        switch c.auth {
        case .clientCertificate: auth = "client certificate"
        case .bearerToken:       auth = "bearer token"
        case .unsupported(let r): auth = "UNUSABLE — \(r)"
        }
        print("\(pad(c.name, 26)) \(pad(c.server.absoluteString, 34)) \(auth)")
    }

case "probe":
    guard args.count == 2 else { die(usage) }
    let client = try KubeClient(context: try loadContext(args[0], args[1]))
    let version = try await client.version()
    let nodes = try await client.nodes()
    print("server      \(version.gitVersion)")
    print("nodes       \(nodes.count) (\(nodes.filter(\.isReady).count) ready)")
    for n in nodes {
        print("  \(pad(n.metadata.name, 40)) \(n.status?.nodeInfo?.architecture ?? "?")  \(n.status?.nodeInfo?.osImage ?? "")")
    }

case "pods":
    guard args.count >= 2 else { die(usage) }
    let client = try KubeClient(context: try loadContext(args[0], args[1]))
    let ns = args.count > 2 && args[2] != "-" ? args[2] : nil
    let sel = args.count > 3 ? args[3] : nil
    let pods = try await client.pods(namespace: ns, labelSelector: sel)
    print("\(pods.count) pods")
    for p in pods.prefix(40) {
        let eph = switch p.container(named: "tmm-stat-exporter") {
        case .durable:   "  [exporter]"
        case .ephemeral: "  [exporter, ephemeral]"
        case nil:        ""
        }
        print("  \(pad(p.metadata.name, 46)) \(pad(p.ready, 6)) \(pad(p.status?.phase ?? "?", 10)) \(p.node)\(eph)")
    }

case "scrape":
    guard args.count >= 4 else { die(usage) }
    let client = try KubeClient(context: try loadContext(args[0], args[1]))
    let port = args.count > 4 ? Int(args[4]) ?? 9099 : 9099
    let started = Date()
    let samples = try await client.scrape(namespace: args[2], pod: args[3], port: port)
    let elapsed = Date().timeIntervalSince(started)
    print("\(samples.count) samples in \(String(format: "%.2f", elapsed))s")
    var families: [String: Int] = [:]
    for s in samples { families[s.name, default: 0] += 1 }
    print("\(families.count) metric families")
    for name in ["f5tmm_up", "f5tmm_tmm_client_side_traffic_cur_conns",
                 "f5tmm_tmm_tm_total_cycles", "f5tmm_scrape_duration_seconds"] {
        for s in samples.filter({ $0.name == name }).prefix(2) {
            print("  \(s.seriesKey) = \(s.value)")
        }
    }

case "bench":
    // Ten scrapes of one pod, holding the tunnel, so the cost of keeping it can
    // be compared with the cost of rebuilding it.
    guard args.count >= 4 else { die(usage) }
    let client = try KubeClient(context: try loadContext(args[0], args[1]))
    let scraper = PodScraper(client: client, namespace: args[2], pod: args[3])
    var kept: [Double] = []
    for _ in 0..<10 {
        let t = Date()
        let s = try await scraper.scrape()
        kept.append(Date().timeIntervalSince(t))
        if kept.count == 1 { print("samples per scrape: \(s.count)") }
    }
    await scraper.stop()
    var fresh: [Double] = []
    for _ in 0..<10 {
        let t = Date()
        _ = try await client.scrape(namespace: args[2], pod: args[3], port: 9099)
        fresh.append(Date().timeIntervalSince(t))
    }
    func stats(_ xs: [Double]) -> String {
        let sorted = xs.sorted()
        return String(format: "first %.3fs  median %.3fs  min %.3fs", xs[0], sorted[xs.count/2], sorted[0])
    }
    print("held tunnel:  \(stats(kept))")
    print("fresh tunnel: \(stats(fresh))")
    print(String(format: "steady-state speedup: %.1fx",
                 (fresh.sorted()[5]) / (kept.dropFirst().sorted()[4])))

case "hold":
    // Scrape one pod every 2s for 120s over a held tunnel, and say how many
    // times the tunnel had to be rebuilt.
    guard args.count >= 4 else { die(usage) }
    let client = try KubeClient(context: try loadContext(args[0], args[1]))
    let scraper = PodScraper(client: client, namespace: args[2], pod: args[3])
    let deadline = Date().addingTimeInterval(120)
    var n = 0, failures = 0
    var durations: [Double] = []
    while Date() < deadline {
        let t = Date()
        do { _ = try await scraper.scrape(); n += 1; durations.append(Date().timeIntervalSince(t)) }
        catch { failures += 1; FileHandle.standardError.write(Data("scrape failed: \(error)\n".utf8)) }
        try? await Task.sleep(for: .seconds(2))
    }
    let sorted = durations.sorted()
    print("scrapes: \(n)  failures: \(failures)  reconnects: \(await scraper.reconnects)")
    if !sorted.isEmpty {
        print(String(format: "per scrape: median %.3fs  max %.3fs", sorted[sorted.count/2], sorted.last!))
    }
    await scraper.stop()

case "logs":
    guard args.count >= 3 else { die(usage) }
    let client = try KubeClient(context: try loadContext(args[0], args[1]))
    let ns = args[2]
    let pods = try await client.pods(namespace: ns).prefix(6).map(\.metadata.name)
    print("following \(pods.count) pods in \(ns)")
    let deadline = Date().addingTimeInterval(12)
    await withTaskGroup(of: Void.self) { group in
        for pod in pods {
            group.addTask {
                do {
                    for try await line in client.logStream(namespace: ns, pod: pod, tailLines: 3) {
                        if Date() > deadline { break }
                        let t = line.at.map { ISO8601DateFormatter().string(from: $0) } ?? "-"
                        print("  [\(line.level.rawValue)] \(t) \(pad(line.pod, 34)) \(line.text.prefix(90))")
                    }
                } catch { print("  \(pod): \(error)") }
            }
        }
        try? await Task.sleep(for: .seconds(12))
        group.cancelAll()
    }

case "exec":
    guard args.count >= 5 else { die("usage: bnkfield exec <kubeconfig> <ctx> <ns> <pod> <container> <cmd...>") }
    let client = try KubeClient(context: try loadContext(args[0], args[1]))
    let command = Array(args.dropFirst(5))
    do {
        for try await chunk in client.exec(namespace: args[2], pod: args[3],
                                           container: args[4], command: command) {
            FileHandle(fileDescriptor: chunk.source == .stderr ? 2 : 1).write(Data(chunk.text.utf8))
        }
        print("\n[exit ok]")
    } catch {
        print("\n[failed] \(error)")
    }

case "nico":
    guard args.count >= 2 else { die(usage) }
    let client = try KubeClient(context: try loadContext(args[0], args[1]))
    let pods = try await client.pods(namespace: "nico-system")
    print("control plane: \(pods.count) pods")
    for p in pods where p.status?.phase == "Running" {
        print("  \(pad(p.metadata.name, 44)) \(p.spec?.containers.first?.image ?? "")")
    }
    if let secret = try? await client.secret(namespace: "nico-system", name: "tmm-lb-admin-cert"),
       let pem = secret.pem("tls.crt"), let cert = try? Certificate.first(inPEM: pem) {
        print("admin cert: subject=\(cert.subject ?? "?") issuer=\(cert.issuer ?? "?")")
        print("            notAfter=\(cert.notAfter) daysLeft=\(cert.daysRemaining) expired=\(cert.isExpired)")
    }
    let tcps = (try? await client.tenantControlPlanes()) ?? []
    print("tenant control planes: \(tcps.count)")
    for t in tcps {
        print("  \(pad(t.metadata.name, 24)) \(t.status?.kubernetesResources?.version?.version ?? "?") " +
              "\(t.isReady ? "Ready" : "not ready")  \(t.status?.controlPlaneEndpoint ?? "-")")
        if let ca = t.status?.certificates?["ca"]?.secretName,
           let ns = t.metadata.namespace,
           let secret = try? await client.secret(namespace: ns, name: ca),
           let pem = secret.pem("ca.crt"), let cert = try? Certificate.first(inPEM: pem) {
            print("      ca: \(cert.subject ?? "?") expires \(cert.notAfter) (\(cert.daysRemaining) days)")
        }
    }

case "install-dryrun":
    // Validates the ephemeral-container patch against a live cluster without
    // writing anything, so the install path can be trusted before a cluster
    // that actually needs it turns up.
    guard args.count >= 2 else { die(usage) }
    let client = try KubeClient(context: try loadContext(args[0], args[1]))
    let pods = try await client.pods(labelSelector: "app=f5-tmm")
    print("dry-running the injection against \(pods.count) f5-tmm pod(s)")
    let outcome = await Exporter.install(into: pods, clusterLabel: "dryrun",
                                         using: client, dryRun: true)
    for pod in outcome.changed { print("  accepted: \(pod)") }
    for pod in outcome.skipped { print("  skipped:  \(pod)") }
    for (pod, reason) in outcome.failed { print("  REJECTED: \(pod)\n            \(reason.prefix(200))") }

    // The pods here already carry an exporter, so the real name collides. Run
    // the identical spec under another name to prove the rest of it -- volumes,
    // securityContext, env, downward API -- is what the apiserver will accept.
    print("\nsame spec, name changed, to validate the rest of it:")
    for pod in pods.prefix(1) {
        guard let ns = pod.metadata.namespace else { continue }
        var spec = Exporter.container(clusterLabel: "dryrun", dssmCert: true)
        spec["name"] = "bnkfield-dryrun"
        let patch: [String: Any] = ["spec": ["ephemeralContainers": [spec]]]
        do {
            _ = try await client.send("PATCH",
                "/api/v1/namespaces/\(ns)/pods/\(pod.metadata.name)/ephemeralcontainers",
                query: ["dryRun": "All"],
                body: try JSONSerialization.data(withJSONObject: patch),
                contentType: "application/strategic-merge-patch+json")
            print("  ACCEPTED by \(pod.metadata.name) — nothing was written")
        } catch {
            print("  REJECTED: \(String(describing: error).prefix(300))")
        }
    }

case "dpu":
    guard args.count >= 2 else { die(usage) }
    let client = try KubeClient(context: try loadContext(args[0], args[1]))
    let chains = try await client.serviceChains()
    let interfaces = try await client.serviceInterfaces()
    print("service chains: \(chains.count)  (\(chains.filter(\.isReady).count) ready)")
    for chain in chains {
        print("  \(pad(chain.metadata.name, 22)) node \(chain.spec.node ?? "?")")
        for (n, sw) in (chain.spec.switches ?? []).enumerated() {
            let ends = (sw.ports ?? []).map { $0.serviceInterface?.described ?? "—" }
            print("      switch \(n) mtu \(sw.serviceMTU.map(String.init) ?? "-"): \(ends.joined(separator: "  <->  "))")
        }
    }
    print("service interfaces: \(interfaces.count)  (\(interfaces.filter(\.isReady).count) ready)")
    for i in interfaces.prefix(6) {
        print("  \(pad(i.spec.interfaceType ?? "?", 9)) \(pad(i.interfaceName, 16)) \(i.detail ?? "")")
    }

default:
    print(usage); exit(2)
}
