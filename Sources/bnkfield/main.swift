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

default:
    print(usage); exit(2)
}
