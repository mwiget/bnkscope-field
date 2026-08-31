# bnkscope Field — demo video

**Format.** One chapter, ~3:40. F5-TTS voiceover cloned from
`tmm-lb-nico/docs/video/kit/voice/marcel.wav`, XCUITest driving the iOS 27 iPad
simulator, `simctl` capture, ffmpeg assembly on lake1.

**Why the tooling splits across two machines.** The simulator only exists on the
Mac, and `capture-bnkscope.js` from the tmm-lb-nico kit drives a *web* console
with Playwright — it cannot drive an iOS app. So capture happens on the Mac and
everything else on lake1, which has ffmpeg, the GPU and the voice reference.

| # | Beat | Narration | On screen |
|---|---|---|---|
| 1 | Cold open | 11.2s | The empty app — "No clusters yet" |
| 2 | Import | 25.9s | Tap Import, cut, the cluster probed: BNK · DPU |
| 3 | Overview | 31.0s | Sorted by trouble; tap a finding, the pod says why |
| 4 | Logs | 24.4s | 24 containers, nothing installed, muting the noisy one |
| 5 | TMM Live | 41.4s | Empty → Add the exporter → charts fill |
| 6 | Terminal | 26.6s | `ip -s link`, then connections |
| 7 | DPU Services | 21.5s | The wiring: p0 → HBN → TMM external/internal |
| 8 | NICo | 27.7s | Second cluster, cert expiry, the cross-cluster link |
| 9 | Close | 11.2s | One connection per cluster |

Total narration: **220.9s (3:41)**.

## The system document picker is not filmed

Beat 2 stops at the tap. What opens next is Apple's picker, in another process,
showing nothing about this app — and it blocks XCUITest teardown, so a take that
opens it hangs until killed. The cut lands on the cluster appearing instead. The
import is real; only the file-browsing is off camera.

## Recording

```bash
KUBE=~/path/to/kubeconfigs ./record.sh all     # or a single beat: ./record.sh 5
```

Each beat is its own take, so a fumbled one costs one re-run. State is staged
before each take rather than carried between them.

### Two things that bite

**A stuck recorder.** An interrupted take leaves the recording session held
inside `CoreSimulatorService`, and every later take fails with *"Host recording
is already in progress"*. Killing the `simctl` wrapper changes nothing — it is
not what holds it. `record.sh` detects the empty file and restarts the service.

**Orientation.** `simctl` captures the framebuffer in portrait whatever the app
is doing, so takes come out sideways and are transposed during assembly. The
direction has not been stable across simulator reboots; check one frame per take
before assembling rather than assuming.
