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
        server: https://203.0.113.20:32170
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
    #expect(c.server.absoluteString == "https://203.0.113.20:32170")
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

// MARK: - Object naming

@Suite("F5 object names")
struct F5NameTests {
    /// Real names, taken from a 2.3.2 cluster running the scenario suite and
    /// from a DPU tenant cluster. The two conventions share no shape, which is
    /// the whole reason the virtual-server panels stopped being tenant-only.
    @Test("The listening address is dropped, the identity kept")
    func trimsAddress() {
        #expect(F5Names.shortObjectName("scn-cwatch-scn-cwatch-gateway-203.0.113.105-http-80-vs")
                == "scn-cwatch-scn-cwatch-gateway")
        #expect(F5Names.shortObjectName("scn-grpc-scn-grpc-l4-gateway-203.0.113.109-tcp-50052-vs")
                == "scn-grpc-scn-grpc-l4-gateway")
        #expect(F5Names.shortObjectName("scn-udp-lb-scn-udp-lb-gateway-203.0.113.107-udp-5005-vs")
                == "scn-udp-lb-scn-udp-lb-gateway")
    }

    /// Two pools of one gateway must not collapse into one line — the rule name
    /// after the port is the only thing telling them apart.
    @Test("Pool rules survive the trim")
    func keepsPoolRule() {
        let a = F5Names.shortObjectName(
            "scn-aitok-dssm-aitok-llm-rag-gw-203.0.113.123-http-8000-aitok-llm-rag-route-rule-0-pool")
        let b = F5Names.shortObjectName(
            "scn-aitok-dssm-aitok-llm-code-gw-203.0.113.121-http-8000-aitok-llm-code-route-rule-0-pool")
        #expect(a == "scn-aitok-dssm-aitok-llm-rag-gw-aitok-llm-rag-route-rule-0")
        #expect(a != b)
    }

    @Test("A name carrying no address is left alone")
    func leavesPlainNames() {
        #expect(F5Names.shortObjectName("tenant-acme-http-vs") == "tenant-acme-http")
        #expect(F5Names.shortObjectName("snat_automap[0]") == "snat_automap[0]")
    }

    /// A four-part run of numbers is only an address if every octet fits.
    @Test("Version-like runs are not addresses")
    func rejectsNonAddresses() {
        #expect(!F5Names.looksLikeIPv4("999.1.1.1"))
        #expect(!F5Names.looksLikeIPv4("1.2.3"))
        #expect(F5Names.looksLikeIPv4("203.0.113.105"))
    }
}

@Suite("Local addresses")
struct LocalAddressTests {

    @Test("the ranges a cluster in a lab actually sits on")
    func privateRanges() {
        // Local Network permission is not an edge case for this app: a
        // kubeconfig nearly always points at one of these.
        #expect(Net.isLocal(host: "192.168.1.10"))     // a home or lab subnet
        #expect(Net.isLocal(host: "10.0.0.1"))         // a routed lab network
        #expect(Net.isLocal(host: "10.244.0.7"))       // a pod address
        #expect(Net.isLocal(host: "172.17.0.1"))       // a docker bridge
        #expect(Net.isLocal(host: "172.31.255.254"))   // the top of 172.16/12
    }

    @Test("names and loopback count as local")
    func names() {
        #expect(Net.isLocal(host: "localhost"))
        #expect(Net.isLocal(host: "apiserver.local"))
        #expect(Net.isLocal(host: "127.0.0.1"))
        #expect(Net.isLocal(host: "169.254.1.1"))
        #expect(Net.isLocal(host: "::1"))
        #expect(Net.isLocal(host: "[fe80::1]"))
    }

    @Test("routable addresses are not local")
    func routable() {
        #expect(!Net.isLocal(host: "8.8.8.8"))
        #expect(!Net.isLocal(host: "172.32.0.1"))      // just past 172.16/12
        #expect(!Net.isLocal(host: "172.15.0.1"))      // just before it
        #expect(!Net.isLocal(host: "193.168.1.1"))     // not 192.168
        #expect(!Net.isLocal(host: "api.example.com"))
        #expect(!Net.isLocal(host: "1.2.3"))           // not four octets
        #expect(!Net.isLocal(host: "999.1.1.1"))       // not an address
    }
}

@Suite("Command lines")
struct ArgvTests {

    @Test("plain commands split on whitespace")
    func plain() {
        #expect(Argv.split("tmctl -d blade tmm_stat") == ["tmctl", "-d", "blade", "tmm_stat"])
        #expect(Argv.split("  ip   -s  link  ") == ["ip", "-s", "link"])
        #expect(Argv.split("") == [])
    }

    @Test("imish needs one argument to hold a whole ZebOS command")
    func quoted() {
        // The reason quoting exists here at all: without it this is six
        // arguments and imish is handed nonsense.
        #expect(Argv.split(#"imish -e en -e "show ip bgp summary""#)
                == ["imish", "-e", "en", "-e", "show ip bgp summary"])
        #expect(Argv.split("imish -e 'show ip route bgp'") == ["imish", "-e", "show ip route bgp"])
    }

    @Test("quotes and backslashes behave as a shell would")
    func escapes() {
        #expect(Argv.split(#"a "b c" d"#) == ["a", "b c", "d"])
        #expect(Argv.split(#"one\ two"#) == ["one two"])
        #expect(Argv.split(#"'a\b'"#) == [#"a\b"#])          // literal inside single quotes
        #expect(Argv.split(#""" x"#) == ["", "x"])            // an empty argument
        #expect(Argv.split(#""unterminated"#) == ["unterminated"])
    }

    @Test("joining is what splitting undoes")
    func roundTrip() {
        for line in [["imish", "-e", "en", "-e", "show ip bgp summary"],
                     ["tmctl", "-d", "blade", "tmm_stat"],
                     ["echo", "a b", "c"],
                     ["weird", #"quote"inside"#]] {
            #expect(Argv.split(Argv.join(line)) == line)
        }
    }
}

// MARK: - k0rdent detection

@Suite("k0rdent")
struct K0rdentTests {

    /// The Sveltos agent's flags are the only place a managed cluster says who
    /// manages it, so parsing them has to survive their exact shape.
    @Test func readsTheSveltosAgentFlags() {
        let args = ["--diagnostics-address=:8443", "--v=0",
                    "--cluster-namespace=kcm-system", "--cluster-name=example-cluster",
                    "--cluster-type=Capi", "--current-cluster=managed-cluster"]
        #expect(KubeClient.flag("--cluster-namespace", in: args) == "kcm-system")
        #expect(KubeClient.flag("--cluster-name", in: args) == "example-cluster")
        #expect(KubeClient.flag("--cluster-type", in: args) == "Capi")
        #expect(KubeClient.flag("--missing", in: args) == nil)
        // A prefix that is not the whole flag name must not match:
        // --cluster-name is not --cluster-namespace.
        #expect(KubeClient.flag("--cluster", in: args) == nil)
    }

    /// A deployment is what the flags are read from, not a pod — pod names churn.
    @Test func readsArgsOffADeployment() throws {
        let json = """
        {"metadata": {"name": "sveltos-agent-manager", "namespace": "projectsveltos"},
         "spec": {"replicas": 1, "template": {"spec": {"containers": [
           {"name": "manager", "image": "projectsveltos/sveltos-agent:v1.12.0",
            "args": ["--cluster-name=example-cluster", "--current-cluster=managed-cluster"]}]}}}}
        """
        let deployment = try KubeClient.decoder.decode(K8s.Deployment.self, from: Data(json.utf8))
        #expect(deployment.podArgs.contains("--current-cluster=managed-cluster"))
    }

    /// Enterprise and community differ in the chart name and nothing else.
    @Test func tellsTheEditionsApartByChartName() throws {
        let json = """
        {"items": [{"metadata": {"name": "k0rdent-enterprise-2-1-0-rc1-2"},
                    "spec": {"version": "2.1.0-rc1.2",
                             "kcm": {"template": "k0rdent-enterprise-2-1-0-rc1-2"},
                             "providers": [{"template": "projectsveltos-1-12-1"}]}}]}
        """
        let list = try KubeClient.decoder.decode(K8s.List<K0rdent.Release>.self, from: Data(json.utf8))
        let release = try #require(list.items.first)
        #expect(release.spec?.version == "2.1.0-rc1.2")
        #expect(release.spec?.kcm?.template?.hasPrefix("k0rdent-enterprise") == true)
    }

    @Test func decodesTheManagementSingleton() throws {
        let json = """
        {"metadata": {"name": "kcm"},
         "spec": {"release": "k0rdent-enterprise-2-1-0-rc1-2"},
         "status": {"release": "k0rdent-enterprise-2-1-0-rc1-2",
                    "availableProviders": ["infrastructure-nico", "infrastructure-internal"],
                    "conditions": [{"type": "Ready", "status": "True"}]}}
        """
        let management = try KubeClient.decoder.decode(K0rdent.Management.self, from: Data(json.utf8))
        #expect(management.isReady)
        #expect(management.status?.availableProviders?.contains("infrastructure-nico") == true)
    }

    /// Discovery has to answer the version, because it is not the same one on
    /// every cluster: a management cluster serves v1beta1, and a cluster that
    /// picked up one stray k0rdent CRD from a service template serves v1alpha1.
    @Test func readsPreferredVersionsFromDiscovery() throws {
        let json = """
        {"groups": [
          {"name": "k0rdent.mirantis.com", "preferredVersion": {"groupVersion": "k0rdent.mirantis.com/v1beta1"}},
          {"name": "kubevirt.io", "preferredVersion": {"groupVersion": "kubevirt.io/v1"}},
          {"name": "nothing.example.com"}]}
        """
        let list = try KubeClient.decoder.decode(K8s.APIGroupList.self, from: Data(json.utf8))
        let map = Dictionary(uniqueKeysWithValues: list.groups.compactMap { group in
            group.preferredVersion.map { (group.name, $0.groupVersion) }
        })
        #expect(map[K0rdent.group] == "k0rdent.mirantis.com/v1beta1")
        #expect(map[KubeVirt.group] == "kubevirt.io/v1")
        #expect(map["nothing.example.com"] == nil)
    }
}

// MARK: - GPUs and KubeVirt

@Suite("KubeVirt")
struct KubeVirtTests {

    /// KubeVirt advertises one extended resource per passable device, named
    /// after the device; the GPU Operator advertises `nvidia.com/gpu`. Both
    /// have to count, and nothing else on the node may.
    @Test func countsGPUsUnderEitherNamingScheme() throws {
        let json = """
        {"metadata": {"name": "worker-1"},
         "status": {"allocatable": {"cpu": "48", "memory": "65536000Ki",
                                    "devices.kubevirt.io/kvm": "1k",
                                    "nvidia.com/GA104GL_RTX_A4000": "2",
                                    "nvidia.com/gpu": "0"}}}
        """
        let node = try KubeClient.decoder.decode(K8s.Node.self, from: Data(json.utf8))
        let gpus = node.gpuResources
        // The zero-count resource is advertised but is not a GPU anyone can have.
        #expect(gpus.count == 1)
        #expect(gpus.first?.name == "GA104GL_RTX_A4000")
        #expect(gpus.first?.count == 2)
    }

    /// A BlueField DPU cluster advertises its scalable functions under the same
    /// vendor prefix a GPU uses. They are NICs. Counting them reported
    /// twenty-six GPUs on a cluster that has none.
    @Test func doesNotMistakeBlueFieldFunctionsForGPUs() throws {
        let json = """
        {"metadata": {"name": "dpu-node-1"},
         "status": {"allocatable": {"cpu": "14",
                                    "nvidia.com/bf_sf": "26",
                                    "nvidia.com/bf_sf_trusted": "12"}}}
        """
        let node = try KubeClient.decoder.decode(K8s.Node.self, from: Data(json.utf8))
        #expect(node.gpuResources.isEmpty)
    }

    @Test func decodesARunningInstanceWithAPassedThroughCard() throws {
        let vmi = try KubeClient.decoder.decode(KubeVirt.VirtualMachineInstance.self,
                                                from: Data(Self.vmiJSON.utf8))
        #expect(vmi.isRunning)
        #expect(vmi.node == "worker-1")
        #expect(vmi.size == "2 vCPU · 4Gi")
        #expect(vmi.gpus.first?.deviceName == "nvidia.com/GA104GL_RTX_A4000")
        // Both addresses, in interface order — the second is the one that
        // carries the tenancy, and reporting only the first hides it.
        #expect(vmi.addresses.map(\.ip) == ["203.0.113.82", "198.51.100.101"])
        #expect(vmi.spec?.networks?.map(\.described) == ["pod", "tenant-a"])
    }

    /// A VMI applied without a VirtualMachine is legal, runs, and cannot be
    /// started or stopped. Pairing on the owner reference would drop it
    /// entirely; pairing on the name keeps it and marks it unmanageable.
    @Test func keepsAnInstanceThatHasNoVirtualMachine() throws {
        let vmi = try KubeClient.decoder.decode(KubeVirt.VirtualMachineInstance.self,
                                                from: Data(Self.vmiJSON.utf8))
        let standalone = KubeVirt.Machine(namespace: "default", name: "tenant-a", vm: nil, vmi: vmi)
        #expect(standalone.isManageable == false)
        #expect(standalone.isRunning)
        #expect(standalone.state == "Running")
    }

    /// A stopped VirtualMachine has no instance at all, so every fact about it
    /// has to come off the template instead.
    @Test func readsAStoppedMachineOffItsTemplate() throws {
        let json = """
        {"metadata": {"name": "halted", "namespace": "default"},
         "spec": {"runStrategy": "Halted",
                  "template": {"spec": {"domain": {"devices": {"gpus": [
                      {"name": "a4000", "deviceName": "nvidia.com/GA104GL_RTX_A4000"}]}},
                    "networks": [{"name": "seg", "multus": {"networkName": "tenant-b"}}]}}},
         "status": {"printableStatus": "Stopped"}}
        """
        let vm = try KubeClient.decoder.decode(KubeVirt.VirtualMachine.self, from: Data(json.utf8))
        let machine = KubeVirt.Machine(namespace: "default", name: "halted", vm: vm, vmi: nil)
        #expect(machine.isManageable)
        #expect(machine.isRunning == false)
        #expect(machine.state == "Stopped")
        #expect(machine.gpus.count == 1)
        #expect(machine.networks.map(\.described) == ["tenant-b"])
    }

    static let vmiJSON = """
    {"metadata": {"name": "tenant-a", "namespace": "default"},
     "spec": {"domain": {"cpu": {"cores": 2, "model": "host-model"},
                         "memory": {"guest": "4Gi", "maxGuest": "16Gi"},
                         "devices": {"gpus": [{"name": "a4000",
                                               "deviceName": "nvidia.com/GA104GL_RTX_A4000"}]}},
              "networks": [{"name": "default", "pod": {}},
                           {"name": "acme", "multus": {"networkName": "tenant-a"}}]},
     "status": {"phase": "Running", "nodeName": "worker-1",
                "interfaces": [{"name": "default", "ipAddress": "203.0.113.82",
                                "mac": "02:00:00:00:00:01", "linkState": "up"},
                               {"name": "acme", "ipAddress": "198.51.100.101",
                                "mac": "02:00:00:00:00:02", "linkState": "up"}]}}
    """
}
