# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and test

```bash
swift build                      # BNKKit + the bnkfield CLI
swift test                       # swift-testing (@Test / #expect), 27 cases
swift test -c release            # CI runs both; see "Release-only bugs" below
swift test --filter parsesClientCertificateContext   # one case

xcodebuild -project App/BNKScopeField.xcodeproj -scheme BNKScopeField \
  -destination 'platform=macOS' build
xcodebuild -project App/BNKScopeField.xcodeproj -scheme BNKScopeField \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```

**Open `App/BNKScopeField.xcodeproj`, not `Package.swift`.** The package window
lists only `bnkfield`, `BNKKit` and `bnkscope-field-Package`; the app target is
not in it, because `Package.swift` does not reference the `.xcodeproj`. Symptom
when you get this wrong: Run keeps launching `bnkfield` and there is no app
scheme to select. Even in the right window `bnkfield` sorts first in the scheme
popup, so check it reads `BNKScopeField` before running. The project uses a
synchronized file group — new files under `App/BNKScopeField/` need no project
edit.

## Never point a second binary at a live kubeconfig

`Identity.swift` imports the client private key into the login keychain, and it
clears old entries first with a delete that matches on the public key's **SHA-1**
rather than on the tag:

```swift
SecItemDelete(scoped([kSecClass: kSecClassKey, kSecAttrApplicationLabel: keyHash]))
```

Same key, same hash — so `bnkfield` finds the app's item whatever tag it was
filed under. Whichever binary adds the key back owns the ACL; the other fails
`PRIVATE_KEY_OPERATION_FAILED` on every request. So on a Mac, run `bnkfield`
against a *copy* of the kubeconfig under a different context name, or on Linux.
Only `bnkfield contexts` is safe — it parses YAML and opens no connection; the
other ten commands all build a `KubeClient`. Recovery is
`security delete-identity -Z <sha1>` plus a re-import from the app.

The app stores imported kubeconfigs in `URL.applicationSupportDirectory/kubeconfigs`
— real cluster credentials. Scripts that touch that directory must save and
restore it.

## Architecture

Two layers, and the split is deliberate: `BNKKit` is transport with no UI, so it
can be exercised against real clusters from the command line before anything is
behind a view. That is what `Sources/bnkfield/main.swift` is for (`contexts`,
`probe`, `pods`, `scrape`, `bench`, `hold`, `logs`, `exec`, `nico`,
`install-dryrun`, `dpu`, `get`).

**Everything reaches a cluster through one door: the apiserver.** Not
minimalism — on the target clusters the control plane has no route to the pod
network, so `services/proxy` and `pods/proxy` time out. What works is what the
apiserver hands to the kubelet:

| | how |
|---|---|
| cluster/node/pod/event reads | plain REST |
| pod logs | `pods/log`, streamed |
| shell in a pod | `pods/exec`, WebSocket, `v5.channel.k8s.io` |
| TCP port in a pod | `pods/portforward`, WebSocket, `v4.channel.k8s.io` |

Port-forward is what makes TMM telemetry possible: TMM hooks inbound TCP on its
dataplane interfaces so `:9099` cannot be dialled from off the pod, but the
kubelet enters the pod's netns and connects to loopback, which the hooking never
sees. The exporter goes in as an **ephemeral container** (no TMM restart), and
`/metrics` is scraped every 2s in parallel across pods. There is no Prometheus in
this path, so history and counter→rate conversion happen on the device; only
derived panel lines are retained (a scrape is ~2,400 series).

`Sources/BNKKit/` — `Kubeconfig` (what the app can act on) · `Identity`
(PEM → `SecIdentity`) · `KubeClient` (one authenticated connection) ·
`PortForward` (tunnel plus a small HTTP client to speak over it) · `Gzip`
(exporter compresses ~20×) · `PromText` (exposition format, gauges only) ·
`K8sTypes` · `Exporter` · `Resources` · `DPUServices` · `PodScraper`.

`App/BNKScopeField/` — SwiftUI on top of BNKKit. `Model/` holds one `@Observable
@MainActor` engine per screen (`TelemetryEngine` is the big one at ~530 lines);
`ClusterStore` owns imported clusters and probing. `Views/` renders them.
`Views/Portable.swift` is the *entire* iOS/macOS divergence — two shims. Keep it
that way; `#if os(...)` elsewhere is a smell.

## Constraints worth knowing before you change something

- **Release-only bugs are real here.** Swift 6.4 `-O` miscompiled a `for await`
  over a task group whose child result was a tuple containing
  `Result<[T], Error>`; a `struct Outcome` element fixed it. No Debug run could
  see it, which is why CI runs `swift test -c release` too. Don't reintroduce
  the tuple shape.
- **Local Network permission on macOS is keyed to code identity** and is
  silently invalidated when the binary at a path is replaced. Re-toggle it in
  System Settings after a rebuild if discovery stops working. Do not attempt to
  sign with another app's identifier to inherit its grant.
- **Deployment targets**: iOS 27 (the OS the target device runs), macOS 15 —
  `presentationSizing` and `.page` in the resource browser are the only macOS 15
  APIs, and 15 is also where per-app Local Network permission arrives. Toolchain
  is Xcode 27; CI uses the newest stable Xcode on the runner.
- **EC client certificates take different calls per platform.** `SecItemAdd`
  with a key reference fails on the macOS file keychain with a message that
  describes nothing; `SecItemImport` handles both curves and RSA and computes
  `kSecAttrApplicationLabel` itself. Match an identity back by certificate bytes,
  never by label — a label query returns whatever the keychain feels like, which
  on a developer Mac is their Xcode signing identity. RSA clusters import fine
  either way, so this stays invisible until an EC cluster shows up.
- **The app runs no binaries.** A kubeconfig with an `exec` credential plugin
  (`aws`, `gcloud`, `kubelogin`) is parsed and kept but marked unusable with the
  binary named in the reason. `tls-server-name` is honoured.
- **Colour is a monitoring convention, not broadcast.** Green means data is
  flowing, red means it is not. The brand red belongs to the mark and nothing
  else — it previously doubled as the live indicator, putting the healthiest
  state on screen in the same colour as STALLED and every destructive button.

## CI

`.github/workflows/macos.yml` — every merge to `main` tests (both
configurations), builds universal, signs with Developer ID, notarizes, staples
and publishes a release. macOS runners bill at 10× the Linux rate, so **nothing
builds on pull requests** and `README.md` / `docs/**` are in `paths-ignore`.

Two checks exist because their failures are silent:
`Tools/check-icns.py` reads the icon chunk table and fails on a missing size (a
partial `.icns` builds and launches fine, macOS just upscales), and
`spctl --assess` must answer `source=Notarized Developer ID` — the one check
that speaks for the downloader's Mac rather than ours.

Signing needs six repository secrets (base64 `.p12` + password + identity name;
base64 `.p8` + key ID + issuer ID). Missing secrets fail the build rather than
falling back to an ad-hoc signature.

## The video

`docs/video/` builds the walkthrough as a re-runnable script, not a performance.
`App/BNKScopeFieldUITests/DemoDrive.swift` drives the app via XCUITest (simctl
has no gesture verbs); each beat is its own test method so one can be re-shot:
`-only-testing:BNKScopeFieldUITests/DemoDrive/beat4Logs`. Note
`record-macos.sh` operates on the real `~/Library/Application Support/kubeconfigs`.
