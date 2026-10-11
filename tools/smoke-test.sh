#!/usr/bin/env bash
# Phone smoke test, run before tagging a release (docs/release-pipeline.md,
# "Smoke test before tagging").
#
# Boots a headless Android emulator (a 411 dp wide phone), starts a
# throwaway machine in Docker (sshd, Herdr and the companion from host/,
# with two fake agents: one waits for a permission, one asks a question),
# and runs integration_test/smoke_test.dart against it with flutter drive.
# One screenshot per step lands in the output folder and in the share
# folder. Exits non-zero when a flow breaks or a layout overflows.
# Emulator, container and network are removed on exit, whatever happens.
#
#   tools/smoke-test.sh [output-dir]
#
# Environment:
#   SMOKE_SHARE_DIR   copy of the screenshots (default
#                     /root/conductore-inbox/out/smoke; empty: none)
#   SMOKE_AVD_HOME    where the AVD lives (default ~/.cache/conductore-smoke)
#   SMOKE_DEVICE      use this running emulator (e.g. emulator-5554)
#                     instead of booting one; it is left running
#
# Never points the emulator at a real machine: the only SSH server it can
# reach is the container, through 10.0.2.2 and a port bound to 127.0.0.1.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ -f /root/.config/conductore/env.sh ] && . /root/.config/conductore/env.sh
: "${ANDROID_HOME:?ANDROID_HOME is not set}"

STAMP=$(date +%Y%m%d-%H%M%S)
OUT=$(mkdir -p "${1:-$ROOT/build/smoke/$STAMP}" && cd "${1:-$ROOT/build/smoke/$STAMP}" && pwd)
SHARE=${SMOKE_SHARE_DIR-/root/conductore-inbox/out/smoke}
AVD_HOME=${SMOKE_AVD_HOME:-$HOME/.cache/conductore-smoke}
AVD=conductore-smoke
IMAGE='system-images;android-34;google_apis;x86_64'
NAME=conductore-smoke-$$
LOCK=/tmp/conductore-build.lock
EMULATOR=$ANDROID_HOME/emulator/emulator
started=$(date +%s)

log() { printf '[smoke %3ss] %s\n' $(( $(date +%s) - started )) "$*"; }
die() { log "FAIL: $*"; exit 1; }

disk_check() {
  local used
  used=$(df --output=pcent / | tail -1 | tr -dc 0-9)
  [ "$used" -le 88 ] || die "disk / is at ${used}%, above 88%"
}

emu_pid= logcat_pid= ctx= serial=
cleanup() {
  local code=$?
  set +e
  [ -n "$logcat_pid" ] && kill "$logcat_pid" 2>/dev/null
  if [ -n "$emu_pid" ]; then
    adb -s "$serial" emu kill >/dev/null 2>&1
    for _ in $(seq 30); do kill -0 "$emu_pid" 2>/dev/null || break; sleep 1; done
    kill "$emu_pid" 2>/dev/null
  fi
  docker rm -f "$NAME" >/dev/null 2>&1
  docker network rm "$NAME" >/dev/null 2>&1
  [ -n "$ctx" ] && rm -rf "$ctx"
  log "cleaned up (exit $code)"
  exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

disk_check
[ -w /dev/kvm ] || die "/dev/kvm is not usable: the emulator needs KVM"
command -v docker >/dev/null || die "docker is missing"
HERDR=$(command -v herdr || true)
[ -n "$HERDR" ] || die "herdr is not on PATH (its binary is copied into the machine)"

# --- SDK pieces and the AVD -------------------------------------------------
if [ ! -x "$EMULATOR" ] || [ ! -d "$ANDROID_HOME/system-images/android-34/google_apis/x86_64" ]; then
  log "installing the emulator and $IMAGE"
  flock "$LOCK" bash -c "yes | sdkmanager --install emulator '$IMAGE'" >"$OUT/sdkmanager.log" 2>&1
fi
export ANDROID_AVD_HOME=$AVD_HOME
if [ ! -f "$AVD_HOME/$AVD.ini" ]; then
  log "creating AVD $AVD (pixel_7, 1080x2400 at 420 dpi = 411 dp wide)"
  mkdir -p "$AVD_HOME"
  echo no | avdmanager create avd -n "$AVD" -k "$IMAGE" -d pixel_7 >"$OUT/avdmanager.log" 2>&1
  # A small data partition, no device frame.
  sed -i -e 's/^disk.dataPartition.size=.*/disk.dataPartition.size=2G/' \
    -e 's/^showDeviceFrame=.*/showDeviceFrame=no/' "$AVD_HOME/$AVD.avd/config.ini"
fi

# --- The throwaway machine ---------------------------------------------------
log "building the smoke machine image"
ctx=$(mktemp -d /tmp/conductore-smoke-ctx.XXXXXX)
cp -R "$ROOT/tools/smoke/machine/." "$ctx/"
mkdir "$ctx/host"
cp -R "$ROOT/host/bin" "$ROOT/host/lib" "$ROOT/host/install.sh" "$ROOT/host/README.md" "$ctx/host/"
[ -d "$ROOT/host/vendor" ] && cp -R "$ROOT/host/vendor" "$ctx/host/"
cp "$(readlink -f "$HERDR")" "$ctx/herdr"
docker build -q -t conductore-smoke-machine "$ctx" >"$OUT/docker-build.log" 2>&1 \
  || { cat "$OUT/docker-build.log"; die "docker build failed"; }

SSH_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
docker network create "$NAME" >/dev/null
docker run -d --rm --name "$NAME" --network "$NAME" -p "127.0.0.1:$SSH_PORT:22" \
  conductore-smoke-machine >/dev/null
for _ in $(seq 60); do
  docker logs "$NAME" 2>&1 | grep -q 'smoke machine ready' && break
  sleep 0.5
done
docker logs "$NAME" 2>&1 | grep -q 'smoke machine ready' || { docker logs "$NAME"; die "the smoke machine did not start"; }
log "machine up on 127.0.0.1:$SSH_PORT (10.0.2.2:$SSH_PORT from the emulator)"

# --- The emulator ------------------------------------------------------------
if [ -n "${SMOKE_DEVICE:-}" ]; then
  serial=$SMOKE_DEVICE
  log "using the running $serial"
else
  port=5554
  while adb devices | grep -q "emulator-$port"; do port=$((port + 2)); done
  serial=emulator-$port
  log "booting $serial"
  # swiftshader: software GL on the host (no GPU here). Impeller's GLES
  # backend crashes this emulator's renderer, so the app runs on Skia
  # (--no-enable-impeller below); Vulkan stays off for the same reason.
  "$EMULATOR" -avd "$AVD" -port "$port" -no-window -no-audio -no-boot-anim \
    -gpu swiftshader_indirect -feature -Vulkan -wipe-data -no-snapshot \
    -memory 2048 -cores 2 >"$OUT/emulator.log" 2>&1 </dev/null &
  emu_pid=$!
  timeout 180 adb -s "$serial" wait-for-device || die "the emulator did not come up"
  for _ in $(seq 120); do
    [ "$(adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break
    kill -0 "$emu_pid" 2>/dev/null || die "the emulator exited (see $OUT/emulator.log)"
    sleep 2
  done
  [ "$(adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] || die "the emulator did not boot"
  for s in window_animation_scale transition_animation_scale animator_duration_scale; do
    adb -s "$serial" shell settings put global "$s" 0
  done
  adb -s "$serial" shell svc power stayon true
  log "booted"
fi
disk_check

# --- The test ----------------------------------------------------------------
adb -s "$serial" logcat -c || true
adb -s "$serial" logcat -v brief >"$OUT/logcat.txt" 2>&1 &
logcat_pid=$!
log "running integration_test/smoke_test.dart"
set +e
(
  cd "$ROOT"
  SMOKE_OUT=$OUT flock "$LOCK" flutter drive \
    --driver=test_driver/integration_test.dart \
    --target=integration_test/smoke_test.dart \
    -d "$serial" --flavor play --no-enable-impeller \
    --dart-define=SMOKE_PORT="$SSH_PORT" \
    --dart-define=CONDUCTORE_SENTRY_DSN= \
    --dart-define=CONDUCTORE_PLAUSIBLE_HOST=
) >"$OUT/drive.log" 2>&1
status=$?
set -e
kill "$logcat_pid" 2>/dev/null || true
logcat_pid=

docker logs "$NAME" >"$OUT/machine.log" 2>&1 || true
docker exec -u smoke "$NAME" sh -c 'cat ~/.conductore/hostd.log 2>/dev/null' >"$OUT/hostd.log" 2>&1 || true
grep -E 'SMOKE step|EXCEPTION|Expected|Actual|overflowed|All tests passed|Some tests failed' "$OUT/drive.log" \
  | sed 's/^I\/flutter ([ 0-9]*): //' >"$OUT/summary.txt" || true
cat "$OUT/summary.txt"

if grep -q 'overflowed by' "$OUT/drive.log" "$OUT/logcat.txt"; then
  status=1
  log "a layout overflowed (RenderFlex): see $OUT/drive.log"
fi
shots=$(find "$OUT" -maxdepth 1 -name '*.png' | wc -l)
if [ -n "$SHARE" ] && [ "$shots" -gt 0 ]; then
  mkdir -p "$SHARE/$STAMP"
  cp "$OUT"/*.png "$OUT/summary.txt" "$SHARE/$STAMP/"
  log "$shots screenshots in $SHARE/$STAMP"
fi
[ "$status" -eq 0 ] || die "smoke test failed (logs in $OUT)"
log "PASS: $shots screenshots in $OUT"
