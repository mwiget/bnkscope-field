# bnkscope Field

An iPad front end for [bnkscope](https://github.com/mwiget/bnkscope), talking to
Kubernetes clusters directly from the device. No Docker, no server, no bnkscope
instance to point at.

`BNKKit` is the transport. It is a plain Swift package with no UI, so it can be
exercised against real clusters from a Mac before any of it is behind a view —
which is what `bnkfield` is for.

```
swift build
.build/debug/bnkfield contexts ~/.kube/config
.build/debug/bnkfield probe    ~/.kube/config my-context
.build/debug/bnkfield pods     ~/.kube/config my-context dpf-operator-system app=f5-tmm
.build/debug/bnkfield scrape   ~/.kube/config my-context dpf-operator-system <tmm-pod> 9099
```

## The one connection

Field reaches a cluster through its apiserver and nothing else. That is not
minimalism for its own sake: on the clusters this was built against, the control
plane has no route to the pod network, so `services/proxy` and `pods/proxy` both
time out. What does work is everything the apiserver hands to the kubelet.

| | how |
|---|---|
| Cluster, node, pod, event reads | plain REST |
| Pod logs | `pods/log`, streamed |
| A shell in a pod | `pods/exec` over WebSocket, `v5.channel.k8s.io` |
| A TCP port inside a pod | `pods/portforward` over WebSocket, `v4.channel.k8s.io` |

The last row is what makes TMM telemetry work without installing anything. TMM
hooks inbound TCP on its dataplane interfaces, so the exporter's `:9099` cannot
be dialled from off the pod — but port-forward is served by the kubelet, which
enters the pod's network namespace and connects to loopback inside it. The
hooking never sees it.

## Credentials

Client certificates and bearer tokens. A kubeconfig that shells out to `aws`,
`gcloud` or `kubelogin` is parsed and kept, but marked unusable with the name of
the binary in the reason — iOS runs no binaries, and a context that quietly
disappears is worse than one that explains itself.

Certificates become a keychain `SecIdentity`, which is the only thing URLSession
will answer a client-certificate challenge with. Two things there are easy to get
wrong and are commented in `Identity.swift`: the key needs its
`kSecAttrApplicationLabel` set to the public-key hash or no identity forms, and
the identity must be matched back by certificate bytes rather than by label — a
label query returns whatever identity the keychain feels like, which on a
developer's Mac is their Xcode signing identity.

## Layout

| | |
|---|---|
| `Kubeconfig.swift` | the parts of a kubeconfig Field can act on |
| `Identity.swift` | PEM → `SecIdentity`, and the DER needed to get there |
| `KubeClient.swift` | one authenticated connection to one apiserver |
| `PortForward.swift` | the tunnel, and a small HTTP client to speak over it |
| `Gzip.swift` | inflation — the exporter compresses ~20× |
| `PromText.swift` | the exposition format, gauges only |
| `K8sTypes.swift` | the API objects the UI renders |

## The app

`App/BNKScopeField.xcodeproj` — a SwiftUI iPad app on top of `BNKKit`. Open it in
Xcode and run; the project uses a synchronized file group, so new files under
`App/BNKScopeField/` are picked up without editing the project.

Two screens so far. **Clusters** imports kubeconfigs, probes each context and
reports what it found — Kubernetes version, node readiness, and BNK / DPF / NICo
detected from pod labels rather than namespace names. **TMM Live** scrapes the
exporter in every f5-tmm pod every two seconds, in parallel, and derives the
panels the Grafana dashboard would: CPU from the cycle counters, throughput and
per-tenant connection rates from the counter deltas, connections straight off the
gauge. Cross-checked against the Prometheus the desktop build feeds — 97.46% and
97.19% CPU there, 97.5% and 97.4% here.

There is no Prometheus in this path, so the two things it would do happen on the
iPad: holding the history, and turning counters into rates. Only the derived
panel lines are kept — a scrape is ~2,400 series, and retaining all of them for
half an hour would cost more than the app is worth.

### Sleep

Backgrounding stops the scrape, because leaving a tunnel open into a live TMM pod
for a session nobody is watching is not free. Two details make that honest rather
than merely quiet:

- The moment the scrape stops is recorded as a break in every line, so the charts
  show a gap. A chart that joins the sample before a sleep to the sample after it
  draws a clean ramp across minutes that were never measured, which is worse than
  a hole because it looks like data.
- The previous frame is dropped on resume, so the first rate after a sleep is a
  baseline rather than a counter differenced over ten minutes.

### Measuring on a real device

Don't use `apiserver_request_total{subresource="portforward"}` for this. It was
the obvious lever — count port-forward requests with the app running and with it
stopped, attribute the difference — and it is worthless here: something else on
this lab port-forwards to the same cluster, at a rate that wanders between 43 and
65 per two minutes. A client that made exactly **one** port-forward request over
a two-minute run sat inside a window where the counter rose by 65.

An earlier version of this file claimed the iPad was managing one scrape every
5.5 s on the strength of that counter. It was noise, not a measurement, and the
number should not be trusted.

What is measured, from a Mac against a live f5-tmm pod:

| | per scrape |
|---|---|
| tunnel held open | median 0.109 s |
| fresh tunnel each time | median 0.188 s |

and a 120-second run at a 2 s interval: 55 scrapes, 0 failures, **0 reconnects** —
the tunnel survives, which is the thing worth knowing.

For the device the honest instrument is the app itself: the LIVE pill shows the
cadence actually being achieved, so read it off the screen rather than inferring
it from the cluster.

### Window sizes

On iPadOS a window is whatever width it is dragged to, so the layout follows the
width rather than the device. Above 900 pt the sidebar is shown; below it the
split view collapses to the detail alone and the tile row wraps. The threshold is
268 pt of sidebar plus a detail column wide enough for two chart panels — below
that the sidebar costs more than it gives.

`NavigationSplitViewVisibility.automatic` is not enough on its own: it hides the
sidebar on a 13-inch in portrait, where there is ample room for it. And because
this app draws its own header rows and hides the navigation bar, the split view's
built-in sidebar button goes with it — hence the explicit toggle, without which a
narrow window has no way back to the cluster list.

### Known gaps

- The cadence on a real device is unmeasured. The LIVE pill reports it; nobody
  has written down what it says.
- No app icon yet.
- Direct mode only. The in-cluster collector, logs and the pod terminal are not
  built.
