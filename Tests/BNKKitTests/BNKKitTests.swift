import Foundation
import Testing
@testable import BNKKit

// MARK: - Kubeconfig

@Test func parsesClientCertificateContext() throws {
    let cfg = try Kubeconfig(yaml: """
    apiVersion: v1
    clusters:
    - cluster:
        certificate-authority-data: Y2E=
        server: https://192.168.68.200:32170
      name: dpu-cplane-tenant1
    contexts:
    - context:
        cluster: dpu-cplane-tenant1
        user: kubernetes-admin
        namespace: dpf-operator-system
      name: kubernetes-admin@dpu-cplane-tenant1
    users:
    - name: kubernetes-admin
      user:
        client-certificate-data: Y3J0
        client-key-data: a2V5
    """)
    #expect(cfg.contexts.count == 1)
    let c = try #require(cfg.context(named: "kubernetes-admin@dpu-cplane-tenant1"))
    #expect(c.server.absoluteString == "https://192.168.68.200:32170")
    #expect(c.namespace == "dpf-operator-system")
    #expect(c.caPEM == Data("ca".utf8))
    #expect(c.auth == .clientCertificate(certPEM: Data("crt".utf8), keyPEM: Data("key".utf8)))
}

/// An `exec:` context must survive parsing and say why it cannot be used —
/// dropping it would leave the user wondering where their cluster went.
@Test func namesTheBinaryAnExecContextNeeds() throws {
    let cfg = try Kubeconfig(yaml: """
    clusters: [{name: eks, cluster: {server: https://example.invalid}}]
    contexts: [{name: eks, context: {cluster: eks, user: eks}}]
    users:
    - name: eks
      user:
        exec:
          command: aws
          args: [eks, get-token]
    """)
    guard case .unsupported(let reason) = cfg.contexts[0].auth else {
        Issue.record("expected an unsupported auth")
        return
    }
    #expect(reason.contains("aws"))
}

@Test func readsBearerTokens() throws {
    let cfg = try Kubeconfig(yaml: """
    clusters: [{name: c, cluster: {server: https://example.invalid}}]
    contexts: [{name: c, context: {cluster: c, user: u}}]
    users: [{name: u, user: {token: abc123}}]
    """)
    #expect(cfg.contexts[0].auth == .bearerToken("abc123"))
}

@Test func rejectsAContextWhoseClusterIsMissing() {
    #expect(throws: Kubeconfig.ParseError.self) {
        _ = try Kubeconfig(yaml: """
        clusters: []
        contexts: [{name: c, context: {cluster: gone, user: u}}]
        users: []
        """)
    }
}

// MARK: - Exposition format

@Test func parsesSamplesWithAndWithoutLabels() {
    let samples = PromText.parse("""
    # TYPE f5tmm_up gauge
    f5tmm_up 1
    # TYPE f5tmm_tmm_client_side_traffic_cur_conns gauge
    f5tmm_tmm_client_side_traffic_cur_conns{pid="59",cpu="0",slot_id="0"} 11
    f5tmm_scrape_duration_seconds 0.019739

    """)
    #expect(samples.count == 3)
    #expect(samples[0] == Sample(name: "f5tmm_up", labels: [:], value: 1))
    #expect(samples[1].labels["pid"] == "59")
    #expect(samples[1].seriesKey == "f5tmm_tmm_client_side_traffic_cur_conns{cpu=0,pid=59,slot_id=0}")
    #expect(samples[2].value == 0.019739)
}

/// Label values are quoted and may contain the characters a naive split would
/// treat as separators.
@Test func parsesLabelValuesContainingSeparators() {
    let s = PromText.parse(#"m{a="x,y",b="he said \"hi\"",c="1"} 5"#)
    #expect(s.count == 1)
    #expect(s[0].labels["a"] == "x,y")
    #expect(s[0].labels["b"] == #"he said "hi""#)
    #expect(s[0].labels["c"] == "1")
}

@Test func readsTheSpecialFloatSpellings() {
    let s = PromText.parse("a NaN\nb +Inf\nc -Inf\n")
    #expect(s[0].value.isNaN)
    #expect(s[1].value == .infinity)
    #expect(s[2].value == -.infinity)
}

@Test func skipsCommentsAndBlankLines() {
    #expect(PromText.parse("# HELP x y\n\n   \n# TYPE x gauge\n").isEmpty)
}

// MARK: - Gzip

/// The fixture is a real `/metrics` body from the published exporter image,
/// captured off the wire — not something generated here. If our inflater and the
/// exporter's compressor ever disagree, this is where it shows.
@Test func inflatesARealScrapeFromTheExporter() throws {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/metrics", withExtension: "gz"))
    let compressed = try Data(contentsOf: url)
    let text = try Gzip.inflate(compressed)

    #expect(compressed.count < text.count / 10, "the fixture should compress at least tenfold")
    let samples = PromText.parse(text)
    #expect(samples.count > 500)
    #expect(samples.contains { $0.name == "f5tmm_up" && $0.value == 1 })
    #expect(samples.allSatisfy { !$0.name.isEmpty })
}

@Test func refusesAThingThatIsNotGzip() {
    #expect(throws: Gzip.Failure.self) {
        _ = try Gzip.inflate(Data(repeating: 0x41, count: 64))
    }
}

// MARK: - HTTP over the tunnel

@Test func parsesAChunklessReplyOffTheWire() throws {
    var raw = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Encoding: gzip\r\n\r\n".utf8)
    raw.append(Data([0x1f, 0x8b, 0x08]))
    let reply = try HTTPReply(raw: raw)
    #expect(reply.status == 200)
    #expect(reply.isGzipped)
    #expect(reply.headers["content-type"] == "text/plain")
    #expect(reply.body == Data([0x1f, 0x8b, 0x08]))
}

@Test func readsANonOKStatus() throws {
    let reply = try HTTPReply(raw: Data("HTTP/1.1 503 Service Unavailable\r\n\r\nnope".utf8))
    #expect(reply.status == 503)
    #expect(!reply.isGzipped)
    #expect(String(decoding: reply.body, as: UTF8.self) == "nope")
}
