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

/// The reply type only. The framing that produces it — status line, headers,
/// then either a Content-Length body or chunked — is read incrementally off a
/// live WebSocket and is not reachable from a unit test without a fake tunnel.
/// It is covered instead by `bnkfield hold`, which ran 55 scrapes against a real
/// f5-tmm pod with 0 failures and 0 reconnects; that exercise is the reason to
/// trust the chunked path, not this test.
@Test func readsAGzippedReplysHeaders() {
    let reply = HTTPReply(status: 200,
                          headers: ["content-type": "text/plain", "content-encoding": "gzip"],
                          body: Data([0x1f, 0x8b, 0x08]))
    #expect(reply.status == 200)
    #expect(reply.isGzipped)
    #expect(reply.headers["content-type"] == "text/plain")
}

@Test func doesNotClaimGzipWithoutTheHeader() {
    #expect(!HTTPReply(status: 503, headers: [:], body: Data("nope".utf8)).isGzipped)
}

// MARK: - Log levels

/// Every string here was taken off dpu-cplane-tenant1, not invented. The first
/// version of the heuristic scored all four of the error cases as `info`.
@Test func classifiesLinesFromARealCluster() {
    let cases: [(String, LogLine.Level)] = [
        (#"{"ts"="2026-08-31 11:25:51.962"|"l"="error"|"m"="failed to create AMQP"}"#, .error),
        (#"{"ts"="2026-08-31 11:25:51.962"|"l"="critical"|"m"="failed to setup exchange"}"#, .error),
        (#"{"ts"="2026-08-31 11:25:51.903"|"l"="info"|"m"="exchange name"}"#, .info),
        ("Aug 31 11:25:52.533248 tmm3[355] conn-sdb – Redis connection establishment with sentinel server failed", .warning),
        ("Aug 31 11:25:51.336241 tmm6[453] conn-db – Trying redis connect with iteration = 119", .info),
        ("I0831 07:38:30.447783   18857 custom_plugin_monitor.go:313] Initialized conditions", .info),
        ("E0831 09:00:43.931896       1 controller.go:150] re-queuing item", .error),
        ("W0831 09:00:43.931896       1 controller.go:150] slow response", .warning),
        (#"level=error msg="upstream refused""#, .error),
        (#"{"level":"warn","msg":"retrying"}"#, .warning),
        ("reconciled Gateway tenant1/edge-gw: 3 listeners, 12 routes attached", .info),
    ]
    for (line, want) in cases {
        #expect(LogLine.Level.guessed(from: line) == want, "\(want) expected for: \(line.prefix(70))")
    }
}

/// The reassuring case a substring search turns into an alarm.
@Test func doesNotRaiseAnAlarmOverTheAbsenceOfErrors() {
    #expect(LogLine.Level.guessed(from: "syncProxyRules took 18.4ms, 0 errors") == .info)
    #expect(LogLine.Level.guessed(from: "health check complete, no errors") == .info)
    #expect(LogLine.Level.guessed(from: "path /var/log/failed/ scanned") == .info)
}

@Test func parsesTheTimestampKubernetesPrefixes() {
    let line = KubeClient.parse("2026-08-31T09:24:18.442839Z hello world", pod: "p", container: "c")
    #expect(line.text == "hello world")
    #expect(line.at != nil)
    #expect(line.pod == "p")
    #expect(line.container == "c")
}

/// A line with no parseable timestamp keeps its whole text rather than losing
/// the first word to a failed parse.
@Test func keepsTheWholeLineWhenThereIsNoTimestamp() {
    let line = KubeClient.parse("plain unprefixed output", pod: "p", container: nil)
    #expect(line.text == "plain unprefixed output")
    #expect(line.at == nil)
}
