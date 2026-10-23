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
#   TILE_PROXY_HOST   Optional. Host of the Cloudflare Worker that holds the
#                     MapTiler key (see proxy/README.md); TILE_PROXY_SCHEME
#                     defaults to https. Without one the capture falls back to
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

BUNDLE_ID="com.aelhamah.GPXNav"
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
# request by anything from half a second to thirty-five seconds. The map
# screen's search button was broken the same way and has been removed for now
# (only the Create tab's search works). Until the presentation host is fixed,
# capturing the flag would only put a copy of the plain route frame on the page.
# See docs/dev.md.
#
# `nav` needs the `LOCATION` fix above more than any other scene does: the
# readout projects the position onto the route, and the map draws it, so without
# a fix there is no dot, no distance left, and no elevation to print. One static
# fix is enough for that -- it is a track record the screen does not have -- so
# `nav` reads as sitting at the route start with the whole distance still to
# walk. `location start --speed` would be needed for the off-course banner,
# which a still capture should not be showing anyway.
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
nav|Navigation|Live guidance|-tab navigate -openFirstRoute -navigate
storage|Offline|Offline storage screen|-tab settings -openStorage
storage-sample|Offline|Offline storage screen, sample download|-tab settings -openStorage -seedStorageSample
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
# #include?s, which is how they reach info.properties in project.yml and from
# there the Info.plist. Never logged, never committed.
# --------------------------------------------------------------------------

# Scheme and host are separate because xcconfig reads `//` as a comment: one
# `TILE_PROXY_BASE_URL = https://host` line would resolve to `https:` and the
# app would silently capture against the demo basemap instead. project.yml
# rejoins them, where no `//` is ever adjacent.
DEMO_TILES=0
if [ -n "${TILE_PROXY_HOST:-}" ]; then
  # `printf '... %s'` rather than an echo so a value with a backslash or a % in
  # it cannot be mangled on the way into the file.
  printf 'TILE_PROXY_SCHEME = %s\nTILE_PROXY_HOST = %s\n' \
    "${TILE_PROXY_SCHEME:-https}" "$TILE_PROXY_HOST" > "$APP_DIR/Secrets.local.xcconfig"
  chmod 600 "$APP_DIR/Secrets.local.xcconfig"
  log "MapTiler: using the configured tile proxy."
else
  DEMO_TILES=1
  warn "No TILE_PROXY_HOST: capturing against the keyless demo basemap."
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
# and no scene is about that dialog. The grants have to come *after* the install
# below: `simctl privacy` on a bundle id that is not installed yet fails, and
# with the failure swallowed the nav frame came back with the dialog over it and
# a readout of zeros, which read as an app fault rather than a capture one.
xcrun simctl location "$UDID" set "$LOCATION" >/dev/null 2>&1 || true

log "Installing"
xcrun simctl install "$UDID" "$APP_PATH"
# `location-always` as well as `location`, so the nav screen's background
# tracking reads as on rather than opening with the warning about the lock
# screen. Nothing else in the app looks at authorisation.
xcrun simctl privacy "$UDID" grant location "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl privacy "$UDID" grant location-always "$BUNDLE_ID" >/dev/null 2>&1 || true

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
# The row stride is a whole number of 32-bit words converted to *bytes*: sips
# writes 32-bit BMPs, where a row of 1206 pixels is 4824 bytes, not the 38592
# that rounding the bit-count and calling it a byte count would give. With the
# wrong stride every row after the first few reads past the end of the file —
# silently, because a slice that far out is just empty — and the sample came
# from the status bar alone.
stride = ((width * bits + 31) // 32) * 4
step = 4 if bits == 32 else 3

colours = set()
for y in range(0, height, 30):             # sampling is plenty to tell flat from drawn
    row = offset + y * stride
    for x in range(0, width, 30):
        colours.add(data[row + x * step:row + x * step + step])
print(len(colours))
PY
}

# Which checks a scene's frame owes.
#
# A scene with a map on it owes three: the basemap must have drawn, the figures
# sheet must be at its expected height, and the map chrome (the rails and pills
# the map screen floats over the basemap) must be present. A tab or settings
# screen owes none of that — there is no basemap to be blank.
scene_class() {
  case "$1" in
    route|route-relief|route-slope|route-terrain|route-satellite) echo collapsed ;;
    route-expanded|route-scrub) echo expanded ;;
    nav)                              echo nav ;;
    *)                                echo none ;;
  esac
}

# Fail the run if a captured map scene is missing its basemap, its sheet, or its
# map controls.
#
# ## What each check is for
#
# The blank-basemap check is the one that matters: a style build that never
# finishes — a refused loopback, a cached style this process never rewrote, a
# joiner that spins the style actor instead of waiting — photographs as a flat
# panel with the route polyline floating on it, and the sheet and chrome are all
# still drawn correctly around it, so nothing else here notices. Flatness is
# measured over the map band only (the sheet below is flat white by design and
# would drown the signal), and a frame fails only when it is *both* almost
# entirely one colour *and* almost colourless: map content that happens to be
# pale stays under the flat threshold, and UI chrome sitting on a genuinely
# blank basemap stays under the colour one.
#
# The sheet check catches a panel that never rose to its detent. The probes
# catch the rails and pills that float over the basemap being absent — they are
# drawn outside the map's own view, so they survive a blank basemap, and a frame
# can therefore be *both* drawn and chromeless.
#
# ## Thresholds, and where the numbers come from
#
# Calibrated against captured frames of every scene plus screen recordings of
# the blank-basemap bug: good frames measure 0.06-0.48 flat, bad ones 0.83-0.96,
# so 0.70 sits well clear of both. Colours are counted quantised to 5 bits per
# channel, matching that calibration. Sheet heights (185pt collapsed, 497pt
# expanded) and the probe centres are measured from the layout itself, in
# points from the bottom/edges, so they hold on any device the picker chooses.
#
# PNG is compressed and a runner is not guaranteed an image library, so the
# frame goes through sips into a BMP first, exactly as frame_colours does. The
# checks themselves run only on real tile captures: with DEMO_TILES the
# keyless demo basemap stands in, and its zoom and styling are different enough
# that it is not the map this calibration was measured on.
assert_frame() {
  local png="$1" id="$2" class bmp
  class="$(scene_class "$id")"
  [ "$class" != "none" ] || return 0
  [ "$DEMO_TILES" != "1" ] || return 0

  bmp="$BUILD_DIR/assert.bmp"
  sips -s format bmp "$png" --out "$bmp" >/dev/null 2>&1 ||
    { warn "could not convert scene '$id' for frame assertions; skipping them"; return 0; }

  local reasons
  # Unquoted on purpose: bash 3.2 scan-checks a quoted heredoc body inside
  # "$(...)" for quote balance, and the body's apostrophes then break parsing.
  if ! reasons=$(python3 - "$bmp" "$class" <<'PY'
import struct, sys

path, mode = sys.argv[1], sys.argv[2]
BANDS = {"collapsed": (0.17, 0.72), "expanded": (0.17, 0.36), "nav": (0.10, 0.62)}
SHEET = {"collapsed": 185, "expanded": 497}          # pt from bottom, detent height
PROBES = {                                            # rails from the left edge,
    "collapsed": [("L", 270), ("R", 319), ("R", 270)],  # left rail is one circle
    "expanded":  [("L", 594), ("R", 643), ("R", 594)],  # since the compass merged
}                                                      # into the locate button
PLAUSIBLE_W = {320, 375, 390, 393, 402, 414, 428, 430, 440}
PLAUSIBLE_H = {568, 667, 736, 812, 844, 852, 874, 896, 926, 932}

data = open(path, "rb").read()
offset = struct.unpack_from("<I", data, 10)[0]
width, height = struct.unpack_from("<ii", data, 18)
bits = struct.unpack_from("<H", data, 28)[0]
comp = struct.unpack_from("<I", data, 30)[0]
bottom_up = height > 0               # positive height stores the bottom row first
h = abs(height)
# Whole 32-bit words in bytes, as in frame_colours: sips writes 32-bit BMPs.
stride = ((width * bits + 31) // 32) * 4
step = 4 if bits == 32 else 3

# Channel order from the BITFIELDS masks when the header declares them, so a
# future sips that writes RGBA rather than BGRA cannot silently turn the blue
# navigate arrow into a missing control. Byte-aligned masks only; anything else
# falls back to the BGRA that sips writes today.
RI, GI, BI = 2, 1, 0
if bits == 32 and comp == 3:
    masks = struct.unpack_from("<3I", data, 54)
    if all(m in (0x000000FF, 0x0000FF00, 0x00FF0000, 0xFF000000) for m in masks):
        RI, GI, BI = [((m & -m).bit_length() - 1) // 8 for m in masks]

# Points per pixel: screenshots are @3x, an occasional runtime hands back @2x.
scale = 3
for d in (3, 2, 1):
    if round(width/d) in PLAUSIBLE_W and round(height/d) in PLAUSIBLE_H:
        scale = d
        break
wpt = round(width/scale)

def rgb(x, y):
    row = offset + ((h - 1 - y) if bottom_up else y) * stride
    i = row + x * step
    return data[i+RI], data[i+GI], data[i+BI]

fails = []

# 1. The basemap must have drawn.
lo, hi = BANDS[mode]
y0, y1 = int(lo*h), int(hi*h)
flat = total = 0
colours = set()
for y in range(y0, y1, 30):
    for x in range(0, width, 30):
        r, g, b = rgb(x, y)
        total += 1
        if (max(r, g, b) - min(r, g, b) <= 16 and min(r, g, b) >= 226) or \
           (max(r, g, b) <= 26 and max(r, g, b) - min(r, g, b) <= 6):
            flat += 1
        colours.add((r >> 3, g >> 3, b >> 3))
flatfrac, distinct = flat/total, len(colours)
if flatfrac > 0.70 and distinct < 250:
    fails.append("blank basemap (flat=%.0f%%, colours=%d)" % (flatfrac*100, distinct))

# 2. The figures sheet must sit at its detent.
#
# Its top edge is the topmost row that is nearly all white *and* stays mostly
# white below it: the map above is speckled with white streets, and the chart
# further down is not white at all, so neither can open the run.
if mode in SHEET:
    top = None
    rows = []
    for y in range(int(0.3*h), h - int(30*scale)):
        c = 0
        for x in range(0, width, 6):
            r, g, b = rgb(x, y)
            if r >= 246 and g >= 246 and b >= 246:
                c += 1
        rows.append((y, c/(width//6)))
    for i, (y, f) in enumerate(rows):
        if f >= 0.75:
            nxt = rows[i+1:i+31]
            if nxt and sum(v for _, v in nxt)/len(nxt) >= 0.50:
                top = y
                break
    if top is None:
        fails.append("sheet missing")
    else:
        got = (h - top)/scale
        if abs(got - SHEET[mode]) > 8:
            fails.append("sheet at %.0fpt, expected %dpt" % (got, SHEET[mode]))

# 3. The map chrome must be present. A control glyph is a dark drawing on a
# light circle, so a box around each centre is counted for dark pixels; the
# white half of that pair is not counted because the circle's material is not
# white on every appearance.
if mode in PROBES:
    half = int(16*scale)
    for side, ypt in PROBES[mode]:
        # 36pt in from the side the control is on. This used to read
        # `width - (wpt-36)*scale` for the right side, which is algebraically
        # just 36*scale — the LEFT edge — so every right-hand probe had been
        # sampling the left rail, and passing only while the left rail had a
        # control at the same heights. One left circle later, it did not.
        cx = int(36*scale) if side == "L" else width - int(36*scale)
        cy = h - int(ypt*scale)
        dark = 0
        for yy in range(max(0, cy-half), min(h, cy+half)):
            for xx in range(max(0, cx-half), min(width, cx+half), 2):
                r, g, b = rgb(xx, yy)
                if (r*299 + g*587 + b*114)//1000 < 110:
                    dark += 1
        if dark < 6:
            fails.append("missing control at %d,%dpt (dark=%d)" % (
                36 if side == "L" else wpt-36, ypt, dark))

print("; ".join(fails))
sys.exit(1 if fails else 0)
PY
  ); then
    die "scene '$id' failed its frame assertions: $reasons"
  fi
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
  # Before the resize: the assertions are calibrated on the full-resolution
  # frame, at the exact pixel scale the thresholds were measured on.
  assert_frame "$raw" "$id"
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

# Actions checks out a pull request as a detached HEAD, so
# `rev-parse --abbrev-ref` answers "HEAD" and the page header says so. The
# workflow's own branch name is the one worth showing.
BRANCH_NAME="${GITHUB_HEAD_REF:-$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)}"

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
  printf '  "branch": "%s",\n'    "$BRANCH_NAME"
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