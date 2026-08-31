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
