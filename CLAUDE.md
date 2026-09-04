# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An iPad and Mac SwiftUI front end for [bnkscope](https://github.com/mwiget/bnkscope): point it at a
kubeconfig and it becomes a live view of a BNK/DPU/NICo Kubernetes cluster — TMM telemetry charts, pod
logs, a command runner, a resource browser, an overview sorted by trouble. No server, no collector, no
bnkscope instance. `README.md` is long and unusually load-bearing: nearly every non-obvious decision in
the code is argued there. Read the relevant section before changing behaviour it describes.

## Where this checkout runs

This machine is `lake1`, a Linux box with **no Swift toolchain and no Xcode**. Nothing in `Sources/`,
`Tests/` or `App/` can be built or tested from here — `BNKKit` imports `Security`, the app is SwiftUI —
so treat Swift edits as unverifiable locally and say so. What does run here is the `docs/video/`
pipeline (ffmpeg, python3, LibreOffice/poppler); `make-slides.sh` shells out to this same host.

## Commands (on a Mac)

```
swift build                     # BNKKit + the bnkfield CLI
swift test                      # Swift Testing; also run -c release in CI
swift test -c release           # a Release-only miscompile has bitten this repo before
swift test --filter parsesClientCertificateContext     # one test

xcodebuild -project App/BNKScopeField.xcodeproj -scheme BNKScopeField \
  -destination 'platform=macOS' build
xcodebuild -project App/BNKScopeField.xcodeproj -scheme BNKScopeField \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```

`bnkfield` is the way to exercise the transport against a real cluster without a view in the way. Its
`usage` string lists only four commands; `main.swift` implements more — `contexts`, `probe`, `pods`,
`scrape`, `bench`, `hold`, `logs`, `exec`, `nico`, `install-dryrun`, `dpu`, `get`.

```
.build/debug/bnkfield probe ~/.kube/config my-context
.build/debug/bnkfield scrape ~/.kube/config my-context dpf-operator-system <tmm-pod> 9099
.build/debug/bnkfield install-dryrun ~/.kube/config my-context   # ?dryRun=All, writes nothing
```

The app icon is generated, not hand-edited:
`swift Tools/make-icon.swift App/BNKScopeField/Assets.xcassets/AppIcon.appiconset App/BNKScopeField/AppIcon.icns`.

## Architecture

**One door: the cluster's apiserver.** On the clusters this was built against the control plane has no
route to the pod network, so `services/proxy` and `pods/proxy` time out. Everything therefore goes
through what the apiserver forwards to the kubelet — plain REST, `pods/log`, `pods/exec`
(`v5.channel.k8s.io`), `pods/portforward` (`v4.channel.k8s.io`). Never add a code path that dials a pod
or service address directly; it will hang in the field.

**`Sources/BNKKit`** — the whole transport, no UI, no platform assumptions beyond Apple's Security and
Foundation. `Kubeconfig` → `Identity` (PEM to `SecIdentity`) → `KubeClient` (one authenticated
connection, two `URLSession`s: a 30 s one for reads and an infinite-timeout one for anything that
streams) → `PortForward` (WebSocket tunnel) → `PodScraper` (holds the tunnel across scrapes; a broken
tunnel is rebuilt, not reported) → `Gzip` + `PromText` (the exporter compresses ~20×). `Exporter`
injects/removes the TMM stat exporter as an **ephemeral container**; its spec is fixed in code, not a
parameter.

**`Sources/bnkfield`** — throwaway CLI presentation over the same calls the app makes.

**`App/BNKScopeField`** — `Model/` holds one `@Observable @MainActor` engine per screen
(`TelemetryEngine`, `LogsEngine`, `ExecEngine`, `NICoEngine`, `OverviewEngine`, `DPUEngine`,
`ResourceEngine`), plus `ClusterStore` (kubeconfigs in Application Support, `ManagedCluster` per
context) and `Navigator` (which screen, and cross-screen "open this object" requests). All of them are
constructed in `BNKScopeFieldApp` and injected as `.environment`; `Views/` reads them and calls
`start`/`stop`. `scenePhase` transitions pause the scrape and close streams — a tunnel into a live TMM
pod is not left open for a session nobody is watching.

**One target, both platforms.** Nothing about transport, parsing or charts is platform-specific. The
only divergence is two SwiftUI calls in `Views/Portable.swift`; keep new `#if os(...)` there rather
than scattering it. Layout follows window *width* (900 pt sidebar threshold in `RootView`), never the
device. The Xcode project uses a synchronized file group, so new files under `App/BNKScopeField/` need
no project edit.

**Deployment targets:** iOS 27 / macOS 15 (the Package manifest says 14; the app needs 15 for
`presentationSizing` and `.page`). Built with the newest stable Xcode, not a beta.

## Conventions that are easy to break

- **Colour is a language.** `Theme.ok/warn/bad` mean something; `Theme.series` deliberately excludes
  those three hues so a chart line never lies about state. `Theme.brand` (the logo red) belongs to the
  mark and nothing else — green means flowing, red means trouble.
- **Charts record gaps.** `Point.v` is optional so a stopped scrape becomes a hole. Never join across a
  pause; a clean ramp over unmeasured minutes looks like data.
- **Writes are almost forbidden.** Installing and removing the exporter is the only thing this app
  writes to a cluster. Removal recreates pods, so it takes a typed confirmation, and is declined
  outright where the exporter is in the pod template.
- **Secrets are not browsable** in Resources. The app reads two by name, for certificate dates.
- **No TTY on exec**, deliberately — `Argv.split`/`join` do shell-style quoting instead, because `imish`
  takes a whole ZebOS command as one argument.
- **Comments carry the reasoning.** The existing style is long "why", not "what" — a comment usually
  names the failure that produced the line. Match it; a bare code change that deletes such a comment
  will reintroduce the bug it documents.
- **Tests use real data.** `Logs.swift`'s level heuristic is tested against lines taken off a cluster,
  including `0 errors` and `/var/log/failed/`. Test fixtures and examples use documentation ranges
  (`203.0.113.0/24`) — no real lab addresses or customer names land in this repo, which is public.

## CI and releases

`.github/workflows/macos.yml` runs on merges to `main` only (macOS runners bill 10× — nothing builds on
PRs, and `README.md`/`docs/**` are path-ignored). It runs both test configurations, builds a universal
Release, signs with Developer ID, notarizes and staples, then publishes a GitHub release. Two checks
exist because their failures are silent: `Tools/check-icns.py` (a partial `.icns` still builds and
launches) and `spctl --assess` having to answer `source=Notarized Developer ID`. Signing needs six
repository secrets; without them the build fails rather than falling back to ad-hoc signing.

## docs/video

A recording pipeline for the demo video, not part of the app. `record-macos.sh` drives the real Mac app
with the XCUITest in `App/BNKScopeFieldUITests/DemoDrive.swift` (one test method per beat, re-shootable
with `-only-testing:`), `make-slides.sh` renders slides from an F5 template that is **not vendored** —
it is internal, this repo is public — and `build-video.sh` cuts takes to the narration, which is the
clock. `build/` and `takes/` are git-ignored. Anything recorded is published: check frames for home
directories, customer names and lab addresses before committing a take or a cut.

## Commits

Subject lines are declarative sentences about the change — "Show the command output, not the walk to
it", "Stop the tests naming a real lab" — never conventional-commit prefixes. Bodies explain what was
wrong and what was tried, including the approaches that failed. Docs-only commits carry `[skip ci]`.
