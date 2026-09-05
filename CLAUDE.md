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

### Dart port (`dart/`)

The Flutter build starts here. `dart/` is a pub workspace with two pure-Dart
packages, no Flutter dependency in either, so everything below runs with
`dart test` on a Linux runner:

- `bnk_kit` is `BNKKit` ported with the same layering, plus the `bnkfield`
  CLI with the same twelve commands and `lib/testing.dart`, a fake apiserver
  on loopback with throwaway certificates.
- `bnk_engines` is `App/BNKScopeField/Model/` ported: one `Observable` per
  screen (`ClusterStore`, `TelemetryEngine`, `LogsEngine`, `ExecEngine`,
  `ResourceEngine`, `OverviewEngine`, `KubeVirtEngine`, `NicoEngine`,
  `DpuEngine`, `ScreenNavigator`). Each mutates its fields and calls
  `notify()`; a view rebuilds on `changes`. Platform wording (`this iPad`,
  where the privacy switch lives) comes in as `DeviceWords` from the app.
- `bnkscope_field` is the Flutter app (iOS, Android, macOS, Windows, Linux).
  `lib/platform.dart` is the *entire* platform divergence, the Flutter
  `Portable.swift`; `lib/observe.dart` is the one adapter from an engine's
  `changes` stream to a widget rebuild; `lib/theme.dart` carries the web
  UI's tokens and the mark. Every screen of the Swift app is ported, one
  file each in `lib/screens/`. Model names that clash with Flutter's were
  renamed on the kit side (`PodContainer`, `ScrapeStatus`) or the widget
  side (`Pill`, `Panel`, `Notice`, `Choice`). Charts are drawn by `lib/chart.dart`'s own painter (monotone
  cubic, gaps kept as gaps, fixed domain where the quantity has one); no
  charting package. To open the app on a given screen for a screenshot,
  launch the binary with `BNK_SECTION=tmmLive BNK_CLUSTER=<display name>`.

The rule that keeps this portable: transport and engines never import a UI
package, and a platform check is allowed only in the view layer's one shim.

```bash
brew install --cask flutter            # brings the Dart SDK
cd dart && flutter pub get && dart analyze --fatal-infos
(cd bnk_kit && dart test)              # 71 cases
(cd bnk_engines && dart test)          # 27 cases, engines driven through the fake apiserver
(cd bnkscope_field && flutter analyze && flutter test && flutter build macos --debug)   # 9 widget tests, four of them against the fake apiserver
(cd bnkscope_field && flutter build linux --debug)     # needs clang, cmake, ninja, libgtk-3-dev
dart run bnk_kit/bin/bnkfield.dart probe <kubeconfig> <context>
(cd bnk_kit && dart compile exe bin/bnkfield.dart -o bnkfield)
```

`flutter pub get`, not `dart pub get`, at the workspace root: the workspace
contains `bnkscope_field`, so plain `dart pub get` cannot resolve
`flutter_test` and fails with "the Flutter SDK is not available" — and then
`dart analyze` reports thousands of unresolved-symbol issues that are only
the failed resolve. The two pure-Dart packages still run under plain
`dart test` once the workspace has been resolved once.

Where each target can be built: **macOS, iOS and Android on a Mac**, **Linux
only on Linux** (`lake1`, which has Flutter under `~/flutter`), **Windows
only on Windows** — the desktop embedders compile against the host's own
toolchain and none of them cross-compiles, so CI is the only place Windows
is built at all. The Mac also needs CocoaPods, because `file_picker` and
`path_provider` carry native code:

```bash
brew install cocoapods openjdk@17
brew install --cask android-commandlinetools
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
yes | sdkmanager --sdk_root="$ANDROID_HOME" --licenses
sdkmanager --sdk_root="$ANDROID_HOME" platform-tools "platforms;android-36" "build-tools;36.0.0"
flutter config --android-sdk "$ANDROID_HOME" --jdk-dir /opt/homebrew/opt/openjdk@17
(cd bnkscope_field && flutter build apk --release)     # debug-signed without key.properties
```

`openjdk@17` is keg-only, so `flutter config --jdk-dir` is what points
Gradle at it; AGP 9.1.0 and Kotlin 2.4.0 both want 17. The Gradle build
installs `platforms;android-35` and `cmake;3.22.1` on its own the first time.

Widget tests that need real sockets (`test/tmm_live_test.dart`) lift the
test binding's HttpClient override and advance fake time with
`tester.pump(duration)` between real-IO waits: a timer created by a widget
callback lives in the fake-async zone and never fires on its own, and any
timer still pending at teardown fails the test, which is why engines cancel
their timers on stop and a cluster closes its client pool on dispose.

`bnkfield install <kubeconfig> <context>` is the app's Add button from the
command line: it injects the exporter into every f5-tmm pod without one.
Nothing restarts, but it is a change to a live cluster.

Intel Linux builds and the Linux test run happen on `lake1` (Dart SDK under
`~/dart-sdk`, workspace rsynced to `~/git/bnkscope-field-dart/`).

**The keychain warning below does not apply to the Dart CLI.** dart:io takes
the client certificate and key as the PEM bytes from the kubeconfig and never
files anything in a keychain, so `bnkfield.dart` can be pointed at the app's
own kubeconfigs under `Application Support/kubeconfigs`. Two facts that were
learned the hard way: `HttpClient.connectionFactory` must return an already
secured socket for https, which is how `tls-server-name` is honoured; and on
macOS/iOS Dart verifies chains through Security.framework, which refuses a
server certificate valid for more than 825 days (the test fixtures are issued
for 800). Two behaviours differ from Swift on purpose: the exec engine fills
the cursor line after a newline instead of printing a blank line at every
frame boundary, and the CPU panel is skipped when the cycle counters have
not advanced, which a fixture that never changes will show you.

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

Two workflows. `.github/workflows/flutter.yml` is the matrix for the Dart
port: a Linux `test` job (both packages and the widget tests, with
`dart analyze --fatal-infos`), then `android` (Linux; APK and AAB, release
keystore from `ANDROID_KEYSTORE` + password, alias and key password, debug
key otherwise), `linux` (Linux; a tarball of the GTK bundle, unsigned, and
the only job that compiles `linux/` at all — the widget tests run headless),
`windows` (Windows runner; zip of the Release folder, signed
with `WINDOWS_CERTIFICATE` + password when present), and `apple` (macOS
runner, **main or `workflow_dispatch` only**: Developer ID signing through
`Tools/sign-flutter-mac-app.sh`, which signs nested frameworks before the
bundle, then notarize, staple and `spctl`; iPadOS is compiled unsigned unless
`IOS_CERTIFICATE`, `IOS_CERTIFICATE_PASSWORD` and `IOS_PROVISIONING_PROFILE`
exist, in which case the `.ipa` goes to TestFlight with the notary key). On
`main`, `release` attaches every build to a release tagged
`app-v<pubspec version>-<run>`. The cheap jobs also run on pushes to
`flutter-port`. The sign script can be dry-run locally with identity `-`.

Two things the Apple job deliberately does not take as secrets, because the
repository already holds them: the team is `DEVELOPMENT_TEAM` in both Xcode
projects, and the App Store Connect key that uploads to TestFlight is the
same `NOTARY_KEY` that notarizes the Mac app. Only the two an iOS
distribution build has no Developer ID equivalent for are new.

**Run the Apple job by hand before trusting it.** It is the one job that a
push to `main` runs for the first time, and it signs, notarizes and
publishes. `workflow_dispatch` takes a `dry_run` input that builds both
Apple targets, signs the Mac app ad hoc through the same script and the same
inside-out order, and then stops: no notarization, no TestFlight upload, no
release. That exercises everything except the certificates themselves.

The job signs twice, so unlike `macos.yml` it makes the keychain in a step of
its own and carries the password in `GITHUB_ENV`: importing the second
identity resets the partition list for every key in the keychain, and setting
it again needs the password the keychain was created with.

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
