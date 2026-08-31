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

## Colour

Green means the data is flowing; red means it is not. That is the opposite of
what the first version did — the logo's red was used for the live indicator,
which put the healthiest state on screen in the same colour as STALLED
(`#EF4444`) and every destructive button in the app. Broadcast convention says a
live light is red; a monitoring convention says red is trouble, and this is a
monitoring tool. The brand red now belongs to the mark and nothing else.

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
cadence actually being achieved. On an iPad Pro M4 against `dpu-cplane-tenant1`
it reads **2.1 s** — the 2 s interval plus a ~0.1 s scrape, matching the held
tunnel above. The loop is doing what it asks for.

Which is also the epitaph for the retracted number: at 0.188 s per fresh-tunnel
scrape the cycle would have been ~2.2 s before this change. Keeping the tunnel
halves the work per scrape and turns one apiserver upgrade per scrape into one
per session, both worth having — but it was never rescuing the app from 5.5 s,
because the app was never at 5.5 s.

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

### Installing the exporter

The Telemetry screen adds the exporter to f5-tmm pods as an **ephemeral
container** and nothing else. The two durable alternatives — patching the
workload, or a mutating admission webhook — both restart TMM, and the webhook
additionally installs a cluster-scoped configuration with a long-lived CA.
Neither belongs behind a button in a troubleshooting tool.

It differs from the desktop build in one way that simplifies it a great deal: no
`TMSTAT_REMOTE_WRITE_URL`. With that empty the exporter serves `/metrics` and
pushes nowhere, and `/metrics` is exactly what Field reads back through the
apiserver. There is no Prometheus to point at, so the heuristic that guesses a
reachable host address for one is not needed either.

The screen shows the image each pod is **actually running**, not the one this app
pins. They are often different: a cluster built with tmmscope carries
`ghcr.io/mwiget/tmm-stat-exporter`, a different repository from the
`bnkscope-tmm-stat-exporter` Field would install, and printing the pinned name
beside a pod running something else is a quiet lie.

The injection is validated against a real cluster without injecting:
`bnkfield install-dryrun` sends the identical patch with `?dryRun=All`, so every
admission plugin runs and nothing is written. On dpu-cplane-tenant1 the apiserver
accepts the spec — volumes, securityContext, downward-API env and all — under a
name that does not collide with the exporter already there.

Removal is deliberately harder than installation, and sometimes refused outright.
An ephemeral container cannot be taken out of a running pod, so clearing one
means recreating the pod — a typed confirmation, not a click, because it drops
dataplane traffic. And where the exporter is **in the pod template** — which is
the case on the DPF cluster this was built against — removal is declined rather
than attempted: deleting the pods would drop traffic and the exporter would come
straight back with the replacements. The screen names the workload it has to be
removed from — "Defined in DaemonSet …" — rather than saying "nothing to do",
which was the first wording and is a contradiction when there plainly is
something there.

### Panels

Double-tap a panel — or double-click, with a trackpad — to give it the whole
window, and again to put it back. There is an expand button in each panel header
too, because a gesture nobody can see is a feature nobody finds, and Escape
closes it for anyone on a keyboard.

### Logs

Followed straight off the apiserver — a container's stdout is captured on the
node and the kubelet streams it back, so nothing is installed for this. What is
missing without a collector is history: the buffer holds what has arrived since
you started following, and no more.

Two things a log view needs that are easy to leave out:

**Muting.** Following two dozen containers is only as useful as the noisiest one
allows. On this cluster a single `sfc-controller` produced almost every line in
the buffer and nothing else could be seen. Muting is display-only — the stream
stays open and the lines stay held, so unmuting shows what was missed rather than
starting over.

**Level detection that knows these logs.** The first version handled klog,
logfmt and JSON and scored a rabbitmq connection failure, a `"l"="critical"` and
a Redis retry storm all as `info`, because F5's CWC logger spells the level
`"l"="error"` — one letter. The heuristic in `Logs.swift` is tested against lines
taken off the cluster rather than invented, including the reassuring cases a
substring search turns into alarms (`0 errors`, `/var/log/failed/`).

### Terminal

Runs a command in a container over `pods/exec` and streams what it prints.
Stdout and stderr are separated, and the exit code arrives on the status channel
— the only place it appears, since the WebSocket closes cleanly either way.

**No TTY, deliberately.** A TTY means a terminal emulator: cursor addressing,
scroll regions, the alternate screen. What this is for is `tmctl`, `configview`
and `bdt_cli` — commands that print and exit — and a shell that cannot run `vi`
would be worse than no shell. There is no shell interpretation either: the
command is split on whitespace and handed to exec, so no quotes and no pipes.

The quick commands were checked against a live tmm pod, which changed two of
them. The first set returned "No such column". The rest had to be trimmed to fit
80 characters, because `tmctl` stacks its table into blocks beyond that and with
no TTY there is nothing to tell it otherwise — it has no width flag and ignores
`COLUMNS`. Pool members are absent for that reason: `pool_name` pads to 63
characters on this cluster so nothing fits beside it, and those numbers are
already a chart on TMM Live.

### The icon

`Tools/make-icon.swift` draws it from the same path data as
`frontend-v2/public/icons/bnkscope-small.svg` in the bnkscope repository, so the
app and the web UI carry one shape rather than two drawings of the same idea.
Run it with `swift Tools/make-icon.swift <out.png>` and drop the result into the
asset catalogue. It fills the square edge to edge — iOS masks its own corners,
and drawing rounded ones underneath that gives a double rounding.

### NICo

The screen appears only on a cluster running NICo, the way bnkscope's tab does.
Most of what the desktop build shows there turns out not to need Forge at all:

| | source |
|---|---|
| nico-api and lb-provider health, images, restarts | plain REST |
| Admin mTLS certificate and its expiry | the `tmm-lb-admin-cert` Secret, parsed |
| Tenant control planes, version, readiness, endpoint | Kamaji CRD, plain REST |
| Tenant cluster CA expiry | each tenant's `ca` Secret |
| nico-api's own counters | a tunnel to its metrics port, same as TMM's exporter |

Certificate dates are parsed from DER in `Certificate.swift` rather than read
through Security, because there is no public way to get a certificate's validity
on iOS: `SecCertificateCopyValues` is macOS only. Expiry is the most useful fact
about a lab certificate, so it is worth the ASN.1.

The one thing missing is the Forge tenant and load-balancer inventory, which
needs gRPC with server reflection and a dynamic protobuf stack. That belongs in
the collector, and the screen says so rather than leaving a blank space.

**The cross-cluster link is the point.** A tenant control plane's endpoint is
matched against the servers Field already holds, so `dpu-cplane-tenant1` in the
sidebar is shown as the cluster that this control plane runs. Nothing else in
the app says the two are related.

### Overview

Answers one question — is anything wrong right now, and where — with the
clusters sorted by trouble rather than by name. It is the screen the app opens
on.

**It does not lead on restart counts, and that is the whole design.** On a
cluster up for sixty days, argo-cd's repo-server has restarted 39 times and is
perfectly healthy; `f5-dssm-sentinel-0` has restarted 157 times and is genuinely
broken. The number does not separate them. What does is that one is not ready
*now* and has warnings still arriving, so readiness and recent warnings carry the
weight and restarts are context shown beside them.

A warning older than half an hour is history rather than a live fault, and a pod
already reported as not-ready does not get a second row saying the same thing in
different words.

### DPU Services

`svc.dpu.nvidia.com` — the API that steers traffic on the DPU. Interfaces are the
ends, chains are the wiring between them, and it is how packets reach HBN and
TMM.

**This is not the DPF operator**, and the distinction cost a screen. The plan was
a DPF tab like bnkscope's; there is no DPF operator on either reachable cluster —
zero `dpu.nvidia.com` CRDs, and live bnkscope reports `not_installed` for the
same cluster. What is there, and populated, is the service API: 2 ServiceChains,
22 ServiceInterfaces, all ready.

The role badge said `DPF` for the same reason and was wrong in the same way. It
is detected from `svc.dpu.nvidia.com/` labels on the TMM pods, which means the
workload is wired through the DPU service API — not that the DPF operator is
installed. It says `DPU` now.

Chains read as they are wired, per node: `p0 ↔ p0_if · hbn`, then
`pf0hpf_if · hbn ↔ external · tmm` and `pf1hpf_if · hbn ↔ internal · tmm`. Those
last two are the same `pf0hpf` and `pf1hpf` the dataplane chart on TMM Live
counts. Read-only: changing how traffic is steered is not something to do from a
tablet by accident.

### Resources

Browse any of eight kinds, filter by namespace, search, and open one to read its
events and its YAML. Deliberately untyped, unlike the rest of `K8s`: the typed
models exist because particular screens render particular fields, and a browser
renders whatever is there.

**Secrets are not offered.** Everything else here is safe on a screen; a Secret's
whole content is its value, and a generic YAML view of one puts cluster
credentials on a tablet in whatever room you happen to be in. The app reads the
two secrets it genuinely needs, by name, for certificate dates.

`managedFields` is stripped from the YAML — server bookkeeping, routinely longer
than the object, and nobody has wanted to read it on a tablet. And
`JSONSerialization`'s output has to be converted to Swift's own types before Yams
will dump it: `NSNull` and `NSNumber` are not things it can represent, and a JSON
`true` is an `NSNumber` that dumps as `1` unless you check for `CFBoolean`, which
would change what the document says.

### Known gaps

- Direct mode only. The in-cluster collector, logs and the pod terminal are not
  built.
