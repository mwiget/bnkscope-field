#!/usr/bin/env bash
# Record one take per beat on the iOS 27 iPad simulator.
#
# Each beat is its own take because a fumbled one should cost one re-run, not a
# whole pass. State is set up before each take rather than carried between them,
# so takes can be shot in any order and re-shot in isolation.
#
# simctl records the framebuffer in portrait whatever the app is doing, so the
# takes come out sideways; assembly transposes them.
set -euo pipefail
SIM="${SIM:-78655525-CAFC-4D60-838F-83D0197E97C2}"
BUNDLE=com.mwiget.bnkscope.field
PROJ="$(cd "$(dirname "$0")/../../App" && pwd)"
OUT="${OUT:-$(cd "$(dirname "$0")" && pwd)/takes}"
DD="${DD:-/tmp/bnkfield-dd}"
KUBE="${KUBE:?set KUBE to a directory holding tenant1.config and infra.config}"

mkdir -p "$OUT"
container() { xcrun simctl get_app_container "$SIM" "$BUNDLE" data; }

# A take that is interrupted leaves the recording session held inside
# CoreSimulatorService, and every later take fails with "Host recording is
# already in progress" — while killing the wrapper process changes nothing,
# because the wrapper is not what holds it. Clearing it means restarting the
# service.
unstick() {
    echo "── clearing a stuck recording session"
    xcrun simctl shutdown all >/dev/null 2>&1 || true
    pkill -f CoreSimulatorService >/dev/null 2>&1 || true
    sleep 5
    xcrun simctl boot "$SIM" >/dev/null 2>&1 || true
    sleep 12
}

# Which kubeconfigs the app should already hold when the take starts.
stage() {
    xcrun simctl terminate "$SIM" "$BUNDLE" >/dev/null 2>&1 || true
    local dir; dir="$(container)/Library/Application Support/kubeconfigs"
    rm -rf "$dir"; mkdir -p "$dir"
    for f in "$@"; do cp "$KUBE/$f" "$dir/"; done
}

take() {
    local name="$1" test="$2"; shift 2
    stage "$@"
    echo "── $name"
    xcrun simctl io "$SIM" recordVideo --codec h264 --force "$OUT/$name.mp4" >/dev/null 2>&1 &
    local rec=$!
    sleep 2
    # test-without-building, not test: a full `xcodebuild test` spends the best
    # part of a minute checking the build before the app appears, and every
    # second of that is home screen in the take.
    #
    # Guarded, because a modal the test failed to dismiss belongs to another
    # process and xcodebuild will wait on it indefinitely rather than fail.
    xcodebuild test-without-building -project "$PROJ/BNKScopeField.xcodeproj" -scheme BNKScopeField \
        -destination "id=$SIM" -derivedDataPath "$DD" \
        -only-testing:"BNKScopeFieldUITests/DemoDrive/$test" >/dev/null 2>&1 &
    local job=$!
    local waited=0
    while kill -0 $job 2>/dev/null && [ $waited -lt ${TAKE_TIMEOUT:-150} ]; do
        sleep 3; waited=$((waited + 3))
    done
    if kill -0 $job 2>/dev/null; then
        echo "   (timed out after ${waited}s — killing)"
        kill -TERM $job 2>/dev/null || true
        pkill -f "xcodebuild test" 2>/dev/null || true
    fi
    wait $job 2>/dev/null || true
    sleep 1
    # simctl writes the file on SIGINT, after the recorder exits — waiting on the
    # job is not enough, the file appears a moment later.
    kill -INT $rec 2>/dev/null || true
    wait $rec 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -s "$OUT/$name.mp4" ] && break
        sleep 1
    done
    if [ -s "$OUT/$name.mp4" ]; then
        printf "   %s\n" "$(ls -lh "$OUT/$name.mp4" | awk '{print $5}')"
    else
        echo "   NO FILE — the recorder was stuck; clearing it, re-shoot this beat"
        unstick
    fi
}

# Built once, so the takes themselves are launch-and-drive.
if [ "${SKIP_BUILD:-0}" != "1" ]; then
    echo "── building for testing"
    xcodebuild build-for-testing -project "$PROJ/BNKScopeField.xcodeproj" -scheme BNKScopeField \
        -destination "id=$SIM" -derivedDataPath "$DD" >/dev/null 2>&1
fi

case "${1:-all}" in
  1) take beat1 beat1Empty ;;
  2) take beat2a beat2ImportTap
     take beat2b beat2ImportResult tenant1.config ;;
  3) take beat3a beat3Overview tenant1.config
     take beat3b beat3Finding tenant1.config ;;
  4) take beat4 beat4Logs tenant1.config ;;
  5) take beat5 beat5TMMLive tenant1.config ;;
  # The install take ends on its confirmation sheet, which covers the thing the
  # install was for. Re-running the same beat once the exporter is in skips the
  # Add and lands on live charts.
  5b) take beat5b beat5TMMLive tenant1.config ;;
  6) take beat6 beat6Terminal tenant1.config ;;
  7) take beat7 beat7DPUServices tenant1.config ;;
  8) take beat8 beat8NICo tenant1.config infra.config ;;
  9) take beat9 beat9Close tenant1.config infra.config ;;
  all) for n in 1 2 3 4 5 5b 6 7 8 9; do "$0" "$n"; done ;;
  *) echo "usage: $0 [1-9|all]"; exit 2 ;;
esac
