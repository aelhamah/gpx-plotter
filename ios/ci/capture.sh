#!/usr/bin/env bash
#
# Build GPXNav, drive it through a fixed set of states in a real iOS Simulator,
# and capture a frame of each into a static web page.
#
# The point is reviewability: a PR that changes ios/ gets a link to the actual
# SwiftUI screens the change produced, without anyone installing Xcode.
#
# `simctl` cannot tap, so nothing here drives the UI directly. Every state is
# reached through the app's own launch arguments (see docs/dev.md), and the
# script's job is to relaunch the app with a different one and take the shot.
# Adding a screen to the preview means adding a row to the scene table below —
# not writing a new automation path.
#
# Run from the repository root:
#
#   ios/ci/capture.sh
#
# Environment:
#   MAPTILER_API_KEY  Optional. A native key (User-Agent allowlisted, not
#                     origin-restricted). Without one the capture falls back to
#                     MapLibre's keyless demo basemap, which is zoom 0-6 only
#                     and switches the terrain overlays off in-app, so the
#                     overlay scenes come out looking broken rather than empty.
#   IOS_DEVICE        Device name filter. Default: iPhone.
#   IOS_RUNTIME       iOS runtime version to prefer. Default: whatever the
#                     installed Xcode's simulator SDK is, falling back to the
#                     newest runtime actually installed.
#   MIN_SETTLE        Floor, in seconds, before a scene may be captured.
#   MAX_SETTLE        Ceiling, in seconds, on a scene that never settles.
#   POLL_SECONDS      How often the screen is sampled while settling.
#   SKIP_VIDEO        Set to 1 to skip the walkthrough recording.
#   OUT_DIR           Where the site is written. Default build/ios-preview/site.
#   SKIP_BUILD        Set to 1 to reuse an existing build in DerivedData.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

APP_DIR="$ROOT/ios/App"
BUILD_DIR="$APP_DIR/build/ios-preview"
DERIVED="$BUILD_DIR/DerivedData"
OUT_DIR="${OUT_DIR:-$BUILD_DIR/site}"
SITE_SRC="$ROOT/ios/ci/site"

BUNDLE_ID="com.example.GPXNav"
SCHEME="GPXNav"
DEVICE_FILTER="${IOS_DEVICE:-iPhone}"
# See settle_and_shoot: MIN_SETTLE is a floor, not a guess at the usual time,
# and MAX_SETTLE is the ceiling on a scene that never settles.
# See settle_and_shoot. MIN_SETTLE is deliberately much larger than the time a
# scene usually needs: a screen that has drawn nothing yet is *stable*, and so
# is a screen part-way through its async start-up, so a short floor captures
# whatever quiet moment it happens to land in. The cost is minutes of waiting;
# the cost of getting it wrong is publishing a half-built screen as the change.
MIN_SETTLE="${MIN_SETTLE:-30}"
MAX_SETTLE="${MAX_SETTLE:-90}"
POLL_SECONDS="${POLL_SECONDS:-4}"
# How many distinct colours a frame must contain before it counts as drawn.
# See frame_colours: an undrawn screen is flat, and flatness is exactly what a
# stability check mistakes for "settled".
MIN_COLOURS="${MIN_COLOURS:-8}"
# Consecutive identical samples required before a frame counts as settled.
STABLE_POLLS="${STABLE_POLLS:-3}"
STILL_MAX_PX=1800
SIM_NAME="GPXNav Preview"
# Maroon Bells, the middle of the seeded demo route in Features/DemoData.swift.
# Without a location the demo launches with no position at all and there is
# nothing for the locate affordance to have anything to say.
LOCATION="39.0986,-106.9398"

log()  { printf '\033[1;34m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

UDID=""

cleanup() {
  [ -n "$UDID" ] || return 0
  log "Removing the capture device ($SIM_NAME)"
  xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
}

on_error() {
  trap - ERR
  cleanup
  printf '\033[1;31m✗\033[0m capture.sh failed on line %s\n' "$1" >&2
  exit 1
}

trap 'on_error $LINENO' ERR
trap cleanup EXIT
# An EXIT trap does not fire when a signal kills the script, and a cancelled CI
# run should not leave a simulator behind for the next one to trip over.
trap 'cleanup; exit 130' INT TERM

# --------------------------------------------------------------------------
# Scenes
#
# id | group | label | launch arguments
#
# `route` is the base: the Maps tab with the seeded demo route pushed. Every
# route scene appends to it, so an overlay scene is that line plus a flag.
#
# `-openSearch` is missing from this table on purpose, and it is a real gap in
# the app rather than an oversight here. ViewerScreen keeps the figures sheet
# presented for as long as the screen is up, and a presentation made while
# another is already up from the same host is dropped rather than queued, so the
# search sheet never appears. It was worth pinning down: the arguments do reach
# the app, `isSearching` really is set, and the sheet content is never even
# evaluated — but neither moving it to a different view in the hierarchy nor
# switching it to a fullScreenCover changes that, and neither does deferring the
# request by anything from half a second to thirty-five seconds. The search
# button on the map has therefore never worked. Until that is fixed, capturing
# the flag would only put a copy of the plain route frame on the page. See
# docs/dev.md.
# --------------------------------------------------------------------------

SCENES=$(cat <<'EOF'
create|Tabs|Create draft tab|-tab create
maps|Tabs|Maps list|-tab navigate
settings|Tabs|Settings|-tab settings
route|Route|Route, stats only|-tab navigate -openFirstRoute
route-expanded|Route|Profile expanded|-tab navigate -openFirstRoute -expandedPanel
route-scrub|Route|Profile scrubbed at 62%|-tab navigate -openFirstRoute -expandedPanel -scrub 0.62
route-relief|Overlays|Relief shading|-tab navigate -openFirstRoute -showRelief
route-slope|Overlays|Slope bands|-tab navigate -openFirstRoute -showSlope
route-terrain|Overlays|3D terrain|-tab navigate -openFirstRoute -terrain3D
route-satellite|Overlays|Satellite basemap|-tab navigate -openFirstRoute -satellite
EOF
)

# The walkthrough is a shorter pass that reads as one continuous session rather
# than a tour of every flag. Seconds per scene, tuned so tiles have landed.
WALKTHROUGH=$(cat <<'EOF'
-tab navigate|4
-tab navigate -openFirstRoute|7
-tab navigate -openFirstRoute -expandedPanel|6
-tab navigate -openFirstRoute -expandedPanel -scrub 0.62|5
-tab navigate|4
-tab settings|4
EOF
)

# --------------------------------------------------------------------------
# Toolchain
# --------------------------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "capture.sh needs macOS with a simulator runtime."

# Created up front rather than inside the build step, because the settle probe
# is written here and SKIP_BUILD skips that step.
mkdir -p "$BUILD_DIR"

if ! command -v xcodegen >/dev/null; then
  log "Installing XcodeGen"
  brew install xcodegen
fi

# --------------------------------------------------------------------------
# Secrets
#
# Written to the gitignored Secrets.local.xcconfig that Secrets.xcconfig
# #include?s, which is how MAPTILER_API_KEY reaches info.properties in
# project.yml and from there the Info.plist. Never logged, never committed.
# --------------------------------------------------------------------------

DEMO_TILES=0
if [ -n "${MAPTILER_API_KEY:-}" ]; then
  # `printf '... %s'` rather than an echo so a value with a backslash or a % in
  # it cannot be mangled on the way into the file.
  printf 'MAPTILER_API_KEY = %s\n' "$MAPTILER_API_KEY" > "$APP_DIR/Secrets.local.xcconfig"
  chmod 600 "$APP_DIR/Secrets.local.xcconfig"
  log "MapTiler: using the configured native key."
else
  DEMO_TILES=1
  warn "No MAPTILER_API_KEY: capturing against the keyless demo basemap."
  warn "  It only has tiles to zoom 6, and the app turns its terrain overlays off"
  warn "  on it, so the relief, slope and 3D scenes will show that explanation."
fi

# --------------------------------------------------------------------------
# Build
# --------------------------------------------------------------------------

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  log "Generating the Xcode project"
  (cd "$APP_DIR" && xcodegen generate --quiet)

  log "Building $SCHEME for the simulator (pulls MapLibre the first time)"
  mkdir -p "$BUILD_DIR"
  BUILD_LOG="$BUILD_DIR/xcodebuild.log"
  # No signing: DEVELOPMENT_TEAM is empty by design and a simulator build needs
  # no identity, so asking for one here would only break CI.
  if ! xcodebuild build \
      -project "$APP_DIR/$SCHEME.xcodeproj" \
      -scheme "$SCHEME" \
      -destination "generic/platform=iOS Simulator" \
      -derivedDataPath "$DERIVED" \
      -clonedSourcePackagesDirPath "$DERIVED/SourcePackages" \
      CODE_SIGN_IDENTITY="" \
      CODE_SIGNING_REQUIRED=NO \
      CODE_SIGNING_ALLOWED=NO \
      >"$BUILD_LOG" 2>&1; then
    tail -n 60 "$BUILD_LOG" >&2
    die "xcodebuild failed. Full log at $BUILD_LOG"
  fi
  tail -n 3 "$BUILD_LOG" | sed 's/^/  /'
fi

APP_PATH="$(find "$DERIVED/Build/Products" -maxdepth 3 -name "$SCHEME.app" -path '*Debug-iphonesimulator*' -type d -print -quit 2>/dev/null || true)"
[ -n "$APP_PATH" ] || die "No $SCHEME.app under $DERIVED. Did the build step run?"
log "App: ${APP_PATH#"$ROOT"/}"

# --------------------------------------------------------------------------
# Simulator
#
# A device of its own, created and deleted around the capture. Reusing an
# existing one would mean erasing it first, which on a developer machine means
# destroying whatever else was on it.
# --------------------------------------------------------------------------

if [ -n "${IOS_RUNTIME:-}" ]; then
  WANT_RUNTIME="$IOS_RUNTIME"
else
  WANT_RUNTIME="$(xcrun --sdk iphonesimulator --show-sdk-version)"
fi

# Tab-separated, because every one of these values contains spaces and `read`
# would otherwise hand "iPhone" to DEVICE_NAME and leave the model in a
# variable nobody reads.
IFS=$'\t' read -r RUNTIME_ID RUNTIME_NAME DEVICE_TYPE DEVICE_NAME < <(python3 - "$WANT_RUNTIME" "$DEVICE_FILTER" <<'PY'
import json, re, subprocess, sys

want_runtime, want_device = sys.argv[1], sys.argv[2]

# IOS_RUNTIME is a bare version number, but "iOS 26.3" is a natural thing to
# type and should not silently read as runtime "iOS iOS 26.3".
want_runtime = re.sub(r"(?i)^ios\s+", "", want_runtime).strip()

def load(*args):
    return json.loads(subprocess.run(args, capture_output=True, text=True).stdout)

# A runtime reports three components ("26.3.1") where a device type reports two
# ("26.3"), so both are reduced to major.minor before they are compared.
def version_tuple(text):
    parts = []
    for chunk in str(text).split("."):
        digits = re.match(r"\d+", chunk)
        if not digits:
            break
        parts.append(int(digits.group()))
    return tuple(parts[:2])

runtimes = [r for r in load("xcrun", "simctl", "list", "runtimes", "--json")["runtimes"]
            if r.get("isAvailable") and r["name"].startswith("iOS")]
if not runtimes:
    sys.exit("no iOS simulator runtime is installed. Add one in Xcode > Settings >\n"
             "Components, or in CI with `xcodebuild -downloadPlatform iOS`.")

# The SDK and the runtime are versioned separately and routinely disagree — an
# Xcode shipping the 26.2 SDK often has the 26.3 runtime and not the other way
# round — so an exact miss falls back to the newest installed rather than
# failing over a version number that was only ever a preference.
exact = [r for r in runtimes if r["name"] == "iOS " + want_runtime]
runtime = (exact or runtimes)[-1]
if runtime["name"] != "iOS " + want_runtime:
    print("note: iOS %s is not installed, using %s" % (want_runtime, runtime["name"]),
          file=sys.stderr)

# Device types carry no isAvailable flag, so availability is "does this runtime
# still support it". Filtering on a key that is not there drops all of them.
runtime_version = version_tuple(runtime["version"])
types = [t for t in load("xcrun", "simctl", "list", "devicetypes", "--json")["devicetypes"]
         if want_device.lower() in t["name"].lower()
         and version_tuple(t["maxRuntimeVersion"]) >= runtime_version]
if not types:
    sys.exit("no %s device type supporting iOS %s on this machine."
             % (want_device, runtime["name"]))

def rank(device_type):
    numbers = [int(n) for n in re.findall(r"\d+", device_type["name"])]
    generation = numbers[0] if numbers else 0
    variant = 2 if "Max" in device_type["name"] else (1 if "Pro" in device_type["name"] else 0)
    return generation, variant, device_type["name"]

# Newest generation first, and within it the largest screen: the expanded sheet
# and the profile chart are the things worth reviewing, and they are laid out
# for a tall viewport.
device_type = sorted(types, key=rank)[-1]
print("\t".join([runtime["identifier"], runtime["name"],
                 device_type["identifier"], device_type["name"]]))
PY
) || die "Could not pick a simulator."

log "Simulator: $DEVICE_NAME on $RUNTIME_NAME"

# Anything left over from a run that was killed rather than exiting.
stale=$(xcrun simctl list devices --json | python3 -c \
  'import json,sys; print("\n".join(d["udid"] for devices in json.load(sys.stdin)["devices"].values() for d in devices if d["name"] == sys.argv[1]))' \
  "$SIM_NAME" 2>/dev/null || true)
for udid in $stale; do
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  xcrun simctl delete "$udid" >/dev/null 2>&1 || true
done

UDID="$(xcrun simctl create "$SIM_NAME" "$DEVICE_TYPE" "$RUNTIME_ID")"
[ -n "$UDID" ] || die "Could not create a simulator."
log "Created $UDID"

xcrun simctl boot "$UDID"

# `simctl bootstatus -b` can sit there indefinitely on the iOS 26 runtimes once
# the device already reports Booted, and a runner that hangs until the job
# timeout produces nothing at all. Readiness is polled instead, bounded, and
# probed against something that genuinely means SpringBoard is up: the device
# can list its installed applications.
for _ in $(seq 1 150); do
  state=$(xcrun simctl list devices --json | python3 -c \
    'import json,sys
d = json.load(sys.stdin)["devices"]
print(next((x["state"] for v in d.values() for x in v if x["udid"] == sys.argv[1]), "Unknown"))' \
    "$UDID" 2>/dev/null || echo Unknown)
  if [ "$state" = "Booted" ] && xcrun simctl listapps "$UDID" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
xcrun simctl listapps "$UDID" >/dev/null 2>&1 || die "the simulator never finished booting"

# Screenshots are the whole output, so the chrome around them is pinned rather
# than left to whatever the runner booted with.
xcrun simctl status_bar "$UDID" override \
  --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 \
  --wifiMode active --wifiBars 3 --dataNetwork wifi >/dev/null 2>&1 || true
xcrun simctl ui "$UDID" appearance light >/dev/null 2>&1 || true

# The location permission dialog would sit on top of the map in every frame,
# and no scene is about that dialog.
xcrun simctl privacy "$UDID" grant location "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl location "$UDID" set "$LOCATION" >/dev/null 2>&1 || true

log "Installing"
xcrun simctl install "$UDID" "$APP_PATH"

# --------------------------------------------------------------------------
# Capture
# --------------------------------------------------------------------------

SHOTS_DIR="$OUT_DIR/shots"
LAUNCHED_AT=0
rm -rf "$OUT_DIR"
mkdir -p "$SHOTS_DIR"

launch() {
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  # shellcheck disable=SC2086 # the argument string is deliberately word-split
  xcrun simctl launch "$UDID" "$BUNDLE_ID" $1 >/dev/null
  LAUNCHED_AT=$SECONDS
}

shoot() {
  local path="$1" attempt
  # `simctl io screenshot` intermittently times out waiting for screen surfaces
  # on the iOS 26 runtimes, especially when the runner is busy compiling
  # something else. That is a capture problem, not an app one, so it is worth a
  # couple of retries rather than failing the run.
  for attempt in 1 2 3; do
    if xcrun simctl io "$UDID" screenshot --type=png "$path" >/dev/null 2>&1; then
      return 0
    fi
    warn "screenshot attempt $attempt failed, retrying"
    sleep 5
  done
  return 1
}


# Whether a frame has actually been drawn on.
#
# A blank screen is *stable* — it photographs identically twice running — so
# waiting for two matching frames cannot tell "the app has finished loading"
# from "the app has not drawn anything yet", and that mistake publishes a white
# screenshot that reads as a bug in the change under review.
#
# PNG is compressed and a runner is not guaranteed an image library, so the
# frame goes through sips into a BMP, which is uncompressed and trivial to read
# directly. An undrawn screen is one flat colour plus the status bar; a drawn
# one carries text, chrome and map data.
frame_colours() {
  local png="$1" bmp="$BUILD_DIR/frame.bmp"
  sips -s format bmp "$png" --out "$bmp" >/dev/null 2>&1 || { echo 0; return; }
  python3 - "$bmp" <<'PY'
import struct, sys

data = open(sys.argv[1], "rb").read()
offset = struct.unpack_from("<I", data, 10)[0]
width, height = struct.unpack_from("<ii", data, 18)
bits = struct.unpack_from("<H", data, 28)[0]
height = abs(height)                       # a negative height means rows run top-down
stride = ((width * bits + 31) // 32) * 32
step = 4 if bits == 32 else 3

colours = set()
for y in range(0, height, 30):             # sampling is plenty to tell flat from drawn
    row = offset + y * stride
    for x in range(0, width, 30):
        colours.add(data[row + x * step:row + x * step + step])
print(len(colours))
PY
}

# Photograph a scene once the screen has stopped changing.
#
# A fixed sleep does not work here. The app's first frame waits on MapLibre
# fetching the style, which is a network round trip: the same scene has measured
# anywhere from twelve seconds to well over thirty on the same machine, and a
# capture taken too early is not a half-drawn map but a blank white screen.
#
# What does hold is waiting for the frame to repeat. A settled scene photographs
# byte-identically twice running — same tiles, same clock, no animation left —
# while a loading one keeps changing. Three conditions have to agree before a
# frame is accepted:
#
#   - the frame has repeated for STABLE_POLLS consecutive samples, so a brief
#     plateau part-way through start-up is not mistaken for the end of it;
#   - MIN_SETTLE seconds have passed, since the quiet phases are long and only
#     a floor rules them out;
#   - the frame has something drawn on it at all.
#
# This is a heuristic, not a readiness signal: nothing outside the app says when
# it is finished. If a frame ever does look half-built, the honest fix is a real
# signal from the app rather than a longer wait here.
settle_and_shoot() {
  local path="$1" probe="$BUILD_DIR/probe.png"
  local previous="" current stable=0
  local deadline=$((LAUNCHED_AT + MAX_SETTLE))

  while :; do
    sleep "$POLL_SECONDS"
    shoot "$probe" || return 1
    current="$(md5 -q "$probe")"

    if [ "$current" = "$previous" ]; then
      stable=$((stable + 1))
    else
      stable=0
    fi
    previous="$current"

    if [ "$SECONDS" -ge $((LAUNCHED_AT + MIN_SETTLE)) ] &&
       [ "$stable" -ge "$STABLE_POLLS" ] &&
       [ "$(frame_colours "$probe")" -ge "$MIN_COLOURS" ]; then
      cp "$probe" "$path"
      return 0
    fi

    if [ "$SECONDS" -ge "$deadline" ]; then
      warn "scene did not settle within ${MAX_SETTLE}s; capturing the last frame anyway"
      cp "$probe" "$path"
      return 0
    fi
  done
}

# The first launch of a fresh install is the one that seeds DemoData, and it is
# also the slowest: the style, the DEM and the loopback tile proxy all have to
# come up before the map draws anything. Every later launch reads the route back
# off disk and hits the warmed tile cache, so this pays the cost once.
log "Warming up (first launch seeds the demo route and primes the tile cache)"
launch "-tab create"
sleep $((MAX_SETTLE + 15))

WIDTH=0 HEIGHT=0

log "Capturing scenes"
while IFS='|' read -r id group label args; do
  [ -n "$id" ] || continue
  printf '  %-16s %s\n' "$id" "$label"
  launch "$args"
  raw="$SHOTS_DIR/$id.png"
  settle_and_shoot "$raw" || die "could not screenshot scene '$id'"
  # A 2622px-tall PNG is a couple of megabytes; eleven of them is a lot of
  # gh-pages for a preview read at about 400px wide.
  sips -Z "$STILL_MAX_PX" "$raw" >/dev/null
  if [ "$WIDTH" -eq 0 ]; then
    read -r WIDTH HEIGHT < <(sips -g pixelWidth -g pixelHeight "$raw" | awk '
      /pixelWidth/  { w = $2 }
      /pixelHeight/ { h = $2 }
      END { print w, h }')
  fi
done <<<"$SCENES"

# --------------------------------------------------------------------------
# Walkthrough
#
# One continuous recording through the main flow, for reviewing motion and
# transitions rather than one particular frame. Optional by design: if the
# runner cannot encode H.264 the stills are still worth publishing on their own,
# so a failed recording downgrades the page instead of failing the run.
# --------------------------------------------------------------------------

VIDEO_REL=""
if [ "${SKIP_VIDEO:-0}" != "1" ]; then
  VIDEO="$OUT_DIR/walkthrough.mp4"
  log "Recording the walkthrough"
  # Genuinely backgrounded: the recorder runs until it is signalled, so it has
  # to be a job rather than a foreground command inside a conditional.
  xcrun simctl io "$UDID" recordVideo --codec=h264 "$VIDEO" >/dev/null 2>&1 &
  VPID=$!
  sleep 3

  if kill -0 "$VPID" 2>/dev/null; then
    while IFS='|' read -r args hold; do
      [ -n "$args" ] || continue
      launch "$args"
      sleep "$hold"
    done <<<"$WALKTHROUGH"

    # The file is only valid once the recorder has flushed and exited.
    kill -INT "$VPID" 2>/dev/null || true
    for _ in $(seq 1 30); do
      kill -0 "$VPID" 2>/dev/null || break
      sleep 1
    done
    wait "$VPID" 2>/dev/null || true

    if [ -s "$VIDEO" ] && [ "$(stat -f%z "$VIDEO")" -gt 20000 ]; then
      VIDEO_REL="walkthrough.mp4"
      log "Walkthrough: $(du -h "$VIDEO" | cut -f1)"
    else
      warn "The recording came out empty; publishing stills only."
      rm -f "$VIDEO"
    fi
  else
    wait "$VPID" 2>/dev/null || true
    warn "Could not start the recorder; publishing stills only."
    rm -f "$VIDEO"
  fi
fi

# --------------------------------------------------------------------------
# Page
# --------------------------------------------------------------------------

log "Writing the page"
cp "$SITE_SRC/index.html" "$SITE_SRC/style.css" "$SITE_SRC/app.js" "$OUT_DIR/"

# Built as JSON first and validated, then wrapped into the assignment the page
# reads. Writing the JS by hand meant one broken substitution — a signalled
# `xcodebuild` under `pipefail`, say — could emit a file that parses as far as
# the browser's first line and then silently shows an empty page.
MANIFEST="$BUILD_DIR/manifest.json"

# `xcodebuild -version` prints two lines and is read without a pipe: `head`
# closes the pipe early, and under `pipefail` the resulting SIGPIPE is a
# non-zero status that fails the run.
XCODE_LINE="$(xcodebuild -version)"
XCODE_LINE="${XCODE_LINE%%$'\n'*}"

{
  printf '{\n'
  printf '  "commit": "%s",\n'    "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  printf '  "branch": "%s",\n'    "$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  printf '  "device": "%s",\n'    "$DEVICE_NAME"
  printf '  "runtime": "%s",\n'   "$RUNTIME_NAME"
  printf '  "xcode": "%s",\n'     "$XCODE_LINE"
  printf '  "capturedAt": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "demoTiles": %s,\n'   "$([ "$DEMO_TILES" = "1" ] && echo true || echo false)"
  printf '  "width": %s,\n'       "$WIDTH"
  printf '  "height": %s'         "$HEIGHT"
  [ -n "$VIDEO_REL" ] && printf ',\n  "video": "%s"' "$VIDEO_REL"
  printf ',\n  "scenes": [\n'
  first=1
  while IFS='|' read -r id group label args; do
    [ -n "$id" ] || continue
    [ $first -eq 1 ] || printf ',\n'
    first=0
    # No id, group, label or argument contains a quote or a backslash, so this
    # is enough to keep the file valid without pulling in a JSON encoder.
    printf '    {"id": "%s", "group": "%s", "label": "%s", "file": "shots/%s.png", "args": "%s"}' \
      "$id" "$group" "$label" "$id" "$args"
  done <<<"$SCENES"
  printf '\n  ]\n}\n'
} > "$MANIFEST"

python3 -m json.tool "$MANIFEST" > /dev/null || die "the scene manifest is not valid JSON: $MANIFEST"

{
  printf 'window.GPXNAV_PREVIEW = '
  cat "$MANIFEST"
  printf ';\n'
} > "$OUT_DIR/scenes.js"

log "Done: $(du -sh "$OUT_DIR" | cut -f1) in ${OUT_DIR#"$ROOT"/}"