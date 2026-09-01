# bnkscope Field

An iPad and Mac front end for
[bnkscope](https://github.com/mwiget/bnkscope), talking to Kubernetes clusters
directly from the device. No Docker, no server, no bnkscope instance to point
at.

## What it is

Point it at a kubeconfig and it becomes a live view of a BNK cluster: TMM CPU,
throughput and connections charted in real time, virtual-server and pool-member
traffic, pod logs, a command runner, a resource browser, and an overview that
sorts clusters by what is actually wrong. It is a troubleshooting tool for
someone standing next to the rack with an iPad, or at a desk with a laptop, not
a replacement for the Grafana stack.

One target builds both platforms. Nothing about the transport, the parsing or
the charts is platform-specific; two SwiftUI calls that exist only on iOS hide
behind shims in `Portable.swift`, and that is the whole of the divergence.

## Getting it

**macOS** — every merge to `main` publishes a signed, notarized universal build:

```
https://github.com/mwiget/bnkscope-field/releases/latest/download/bnkscope-Field-macOS.zip
```

Unzip, drag to `/Applications`, open. macOS 15 or later, Apple Silicon or Intel.
The notarization ticket is stapled into the bundle, so it opens on a Mac that is
offline at first launch. You can check who built it before trusting it:

```
spctl --assess --type execute -vvv "/Applications/bnkscope Field.app"
# accepted
# source=Notarized Developer ID
# origin=Developer ID Application: Marcel Wiget (HGECWA98QL)
```

**iPad** — no TestFlight build yet; open the project in Xcode and run it on a
device.

### First run, on either

The app talks to apiservers on your own network, and both platforms gate the
local subnet behind a per-app permission. Grant **Local Network** when asked,
then **relaunch** — the permission is only read while a connection is being set
up, so granting it to an app that is already running changes nothing until it
restarts. A denial arrives as `NSURLErrorNotConnectedToInternet`, the same code
a genuinely offline device reports, so the app tells the two apart by whether
the address is one only the local network can reach.

## How it works

Import one or more kubeconfigs — a multi-context `~/.kube/config` is split into
one cluster per context on import, so each can be removed on its own. Client
certificates become keychain identities and bearer tokens are kept as they are;
a context that shells out to `aws` or `kubelogin` is kept but marked unusable,
because the app runs no binaries.

Everything then goes through **one door: the cluster's apiserver**. Reads are
plain REST, logs stream from `pods/log`, commands run over `pods/exec`, and —
the part that makes live telemetry possible — a TCP port inside a pod is reached
through `pods/portforward`. Nothing is installed on this side of the network and
no inbound access to the cluster is needed.

For TMM telemetry the app injects a small exporter into each `f5-tmm` pod as an
**ephemeral container**, which does not restart TMM. It then holds a port-forward
tunnel open and scrapes `/metrics` every two seconds, in parallel across pods.
There is no Prometheus in this path, so the two things Prometheus would do happen
on the device: keeping the history, and turning counters into rates. An
**Add** and a **Remove** button on TMM Live put the exporter in and take it out
again; removal recreates the pods, so it asks for a typed confirmation.

Backgrounding the app on iPadOS stops the scrape and closes the tunnel, and the
resumed charts show a gap rather than a line drawn across minutes nobody
measured. A Mac window that is merely behind another keeps scraping, because it
was never suspended.

Windows are whatever width you drag them to, and the layout follows the width
rather than the device.

## Building it

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

The app itself builds for both platforms from the one target:

```
swift test
xcodebuild -project App/BNKScopeField.xcodeproj -scheme BNKScopeField \
  -destination 'platform=macOS' build
xcodebuild -project App/BNKScopeField.xcodeproj -scheme BNKScopeField \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```

## Releases

Every merge to `main` builds, tests, signs, notarizes and publishes the Mac app
— `.github/workflows/macos.yml`. The download above always points at the newest.

Two of its checks exist because the failures they catch are silent ones:

- `Tools/check-icns.py` reads the icon's chunk table and fails on a missing size.
  A partial icon still builds and still launches — macOS just scales up the
  largest size it finds — so nothing about a green build tells you. Not
  hypothetical: given a classic appiconset, `actool` emitted four of the ten
  sizes, and the Dock was upscaling a 256 to 1024. The Mac icon is now built by
  `iconutil`, which given the very same PNGs writes all ten.
- `spctl --assess` must answer `source=Notarized Developer ID`. Every other
  check in the build speaks for the machine that made the app; this one speaks
  for the machine downloading it.

Signing needs six repository secrets: the Developer ID certificate as a base64
`.p12` with its password, the identity name, and an App Store Connect API key —
base64 `.p8`, key ID, issuer ID — for `notarytool`. Without them the build fails
rather than quietly falling back to an ad-hoc signature Gatekeeper would reject.
The certificate is imported into a keychain created for the run and discarded
with it; `security set-key-partition-list` is what stops `codesign` blocking on
a GUI prompt nobody can answer.

macOS runners bill at ten times the Linux rate, which is why nothing builds on
pull requests.

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

`tls-server-name` is honoured. A cluster reached through a forward — a lab
apiserver bound to loopback, republished on another address — presents a
certificate for the name it knows itself by, not the one you dialled. Without
this field the only way to use such a cluster is to turn verification off
altogether, which is a far bigger hammer than the problem.

**EC client certificates need different calls on each platform.** microk8s and
k3s both issue them, and the macOS file keychain refuses an EC key handed to
`SecItemAdd` as a reference: every attribute combination returns "the specified
item is no longer valid", which describes nothing. Stating `kSecAttrKeyType` is
what makes the same call work on iOS, and it does not transfer. `SecItemImport`
— the macOS-native importer — takes both curves and RSA, and computes
`kSecAttrApplicationLabel` itself, which is the attribute the identity pairing
is looked up by. Deleting a cluster removes its key by that hash rather than by
tag, because the file keychain accepts an `applicationTag` and then will not
search on it.

This was invisible for a long time because RSA clusters import fine either way.
Only the one cluster with an EC cert failed, and it failed before reaching the
network, so it looked like a connectivity problem.


Client certificates and bearer tokens. A kubeconfig that shells out to `aws`,
`gcloud` or `kubelogin` is parsed and kept, but marked unusable with the name of
the binary in the reason — the app runs no binaries on either platform, and a
context that quietly disappears is worse than one that explains itself.

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

## Toolchain

Xcode 27 and the iOS 27 SDK, deployment target 27 — the OS the device this was
built for actually runs. Building against 26 and deploying to a 27 device worked,
but only by accident of compatibility.

macOS deploys back to **15**, which is as far as it reaches: `presentationSizing`
and `.page` in the resource browser are macOS 15 APIs and the only things that
need more than 14. That floor is also where per-app Local Network permission
arrives, so a Mac that can run this is a Mac that has the permission model the
app expects. CI builds with the newest stable Xcode the runner has rather than a
beta — verified against 26.6 and the macOS 26.5 SDK.

Xcode 27's stricter concurrency checking is worth having: it caught a `@Sendable`
closure capturing two `ISO8601DateFormatter`s, and a dead local kept alive by a
`_ = run` that existed only to quiet the compiler.

## The app

`App/BNKScopeField.xcodeproj` — a SwiftUI app for iPadOS and macOS on top of
`BNKKit`. Open it in Xcode and pick a destination; the project uses a
synchronized file group, so new files under `App/BNKScopeField/` are picked up
without editing the project.

**Clusters** imports kubeconfigs, probes each context and
reports what it found — Kubernetes version, node readiness, and BNK / DPF / NICo
detected from pod labels rather than namespace names. **TMM Live** scrapes the
exporter in every f5-tmm pod every two seconds, in parallel, and derives the
panels the Grafana dashboard would: CPU from the cycle counters, throughput and
connection rates from the counter deltas, connections straight off the gauge.

Virtual servers and pool members get panels of their own, and they are named as
the cluster names them. The per-tenant panels read a `tenant-<name>-...`
convention that only the DPU clusters follow; a cluster naming its virtual
servers `scn-<scenario>-...-vs` had every series filtered out and showed tmm
counters with nothing about the traffic passing through them. A virtual server
earns a line by having carried a connection — a cluster has one per route whether
or not anything uses it, and fourteen flat zeroes are worse than nothing. Cross-checked against the Prometheus the desktop build feeds — 97.46% and
97.19% CPU there, 97.5% and 97.4% here.

There is no Prometheus in this path, so the two things it would do happen on the
device: holding the history, and turning counters into rates. Only the derived
panel lines are kept — a scrape is ~2,400 series, and retaining all of them for
half an hour would cost more than the app is worth.

### A cluster that changes underneath

The pod roster is re-listed while TMM Live is open, because it does change: a
scenario restarts a tmm pod, and the pod that comes back carries no ephemeral
container. Without the re-list the screen went on scraping a pod that was gone,
offered to remove an exporter that already was, and had no way to put it back —
the stale pod still carried the exporter in its spec, so nothing was reported
missing. The engine retargets to the new roster without discarding the graphs,
and the failure state carries the targets card so the exporter can be re-injected
from where it broke.

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

The wordmark sits at the sidebar's trailing edge on iPadOS and its leading edge
on macOS, and the difference is not taste. iPadOS draws its close/minimise/resize
controls over the top-left of the content and insets nothing to make room, so a
mark in the corner lands underneath them and, worse, so does the button that
reopens a collapsed sidebar. Centring is not enough — the row is about 180 pt
wide in a 268 pt column. A Mac keeps those controls in a real title bar above the
content, so there is nothing to dodge.

### Installing the exporter

Installing and removing the exporter lives on **TMM Live**, not in a menu entry
of its own. It had one, and it was wrong twice over: it put a thing you configure
beside seven things you look at, and it split one subject in two — TMM Live
listed which pods carried the exporter and could do nothing about it, while
another screen could act but showed no graphs. The state and the actions belong
on the screen that is empty without them.

So the Exporter targets card carries Add and Remove, and a cluster whose TMM pods
have no exporter gets an install prompt where the charts would be, rather than a
dead end reading "looking for TMM pods".

TMM Live adds the exporter to f5-tmm pods as an **ephemeral
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
would be worse than no shell. There is no shell on the far side either, so pipes
and redirection genuinely do not work and are not faked.

Quotes do work, and have to. `Argv.split` honours single quotes, double quotes
and backslash the way a shell would, because `imish` takes a whole ZebOS command
as a single argument: split on spaces, `show ip bgp summary` becomes four
arguments and imish is handed nonsense. `Argv.join` is its inverse, so the
command echoed above each result is one that can be edited and run again rather
than a lossy rendering of what ran.

**The container is chosen, not assumed.** This screen hard-wired `debug` for as
long as `tmctl` was the only tool worth reaching, and the picker it once had
really was clutter pretending to be a control. `imish` changes that: the ZebOS
shell lives only in `f5-tmm-routing`, so selecting it swaps the diagnostics for
BGP summary, neighbors, routes, BFD and running-config. Those run through
`imish -e`, one command per flag, because bare `imish` is interactive and would
wait forever for input that cannot arrive without a TTY.

The prompt suggests a command rather than showing a placeholder. A placeholder
is the one thing it cannot be — an offer: there is no way to accept it and it
vanishes at the first keystroke, so it showed a command and then took it away
exactly when someone tried to use it. The suggestion is drawn behind the field
with the typed part rendered clear, so its tail starts at the caret, and **Tab**
accepts it. An iPad without a keyboard has no Tab key, so the hint is also a
button.

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
Run it with

```
swift Tools/make-icon.swift App/BNKScopeField/Assets.xcassets/AppIcon.appiconset \
                           App/BNKScopeField/AppIcon.icns
```

which writes both platforms' artwork. They differ, and not decoratively. The iOS
image fills the square edge to edge, because iOS masks its own corners and
drawing rounded ones underneath gives a double rounding. macOS masks nothing, so
its icon is the mark inset in a rounded square on Apple's grid — 824pt centred on
1024 — with the margin left transparent.

The Mac icon is an `.icns` built here by `iconutil` rather than left to the asset
catalogue. Handed a classic appiconset, actool in Xcode 27 emits four of the ten
sizes — 16, 32, 128 and 256 — and the Dock then scales a 256 up to 1024, which
shows. `iconutil`, given exactly the same PNGs, writes all ten. `App/Info.plist`
exists only to carry `CFBundleIconFile`, which is the one key Xcode's generated
Info.plist has no `INFOPLIST_KEY_` for.

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

- **Direct mode only.** There is no in-cluster collector, so history is whatever
  the app has been open for: charts hold half an hour, and the log buffer holds
  what has arrived since you started following.
- **No Forge inventory on the NICo screen.** It needs gRPC with server reflection
  and a dynamic protobuf stack; the screen says so rather than leaving a blank.
- **Read-only where it matters.** Installing and removing the exporter is the
  only thing this app writes to a cluster. Service chains, workloads and
  everything in the resource browser are shown, not edited.
- **Secrets are not browsable**, deliberately — see Resources above.
- **The Mac app is not sandboxed.** It has unrestricted filesystem and network
  access once launched. Fine for a tool you build yourself; something a
  corporate security review would reasonably ask about.
- **No TestFlight build for the iPad.** The Mac side has a signed, notarized
  download; the iPad still needs Xcode and a cable.
