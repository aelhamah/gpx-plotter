# Device-only checks

The behaviour this app gets wrong tends to be the behaviour a simulator cannot
reach. `simctl` can synthesise a *path* through a route, but it cannot lock a
phone, tap, long-press, present a permission alert, rotate a compass, or lose its
network — and every check below lives in that gap.

Getting the app onto the phone is [device-troubleshooting.md](device-troubleshooting.md);
this file starts once it is installed and launching. §0 explains why each check is
here rather than in the simulator section of [dev.md](dev.md).

Run them in order. They are ordered by dependency, not by importance.

---

## 0. What the simulator cannot do, and why that matters here

| Simulator | Physical device |
| --- | --- |
| `simctl launch` passes arguments | same |
| `simctl location set/start` synthesises a path | same |
| cannot lock the screen | the whole point of background location |
| cannot tap or long-press | every button in the Live Activity |
| cannot grant a permission alert | first-run authorisation |
| **no compass heading at all** | heading-up tracking |
| shares the host's network, cannot lose it | airplane mode |
| no microphone/sensor permission flow | background audio |

The compass row is the one that surprises people most. `simctl location` moves
the *position*; it does not simulate a magnetometer, so `CLLocationManager`
reports no heading and every heading-dependent code path takes its "no heading"
branch. A needle that renders and a needle that turns are different claims, and
only a device can make the second one.

**Known simulator nuisance, not an app fault.** On iOS 27 simulators the location
permission alert cannot be suppressed: `simctl privacy … grant location` returns
success but writes nothing, and seeding `TCC.db` by hand (`kTCCServiceLiverpool`)
does not stop the prompt either. Captures here will have the alert over part of
the frame. The device does not have this problem — answering it once is enough.

---

## 1. Live Activity controls

The controls are the reason intents were moved into `Shared`: an
`AppIntent` has to exist in *both* binaries for the system to offer it in both
places, and the widget's copy alone leaves the app unable to receive what the
widget sends.

1. Import a route, start navigation, and lock the phone.
2. On the lock screen, tap **Pause**. The readout should stop advancing and the
   state glyph should change.
3. Tap **Resume**. It advances again.
4. Tap **End**. The activity should disappear, *and* the app should come back with
   its navigation screen gone — not still running underneath.
5. Start again, and this time press **End in the app**, then check the lock
   screen. There must be no orphaned activity left behind.
6. Expand the Dynamic Island (long-press down from the pill) and use the controls
   there. They must do the same things.

**Pass:** pause, resume and end each take effect once, from either surface, and no
activity survives an end from the other one.

**Why here:** no taps, no lock screen, and no way to see a lock-screen widget.

**Fails if:** End leaves the activity up, or the app's navigation screen is still
there after a lock-screen end — that is the one-way path where the two copies of
the command disagree.

---

## 2. Bearing, not screen rotation

This is the map pointing where you are facing. Turning the *phone* is only how you
make it happen.

1. Start navigation on any route. The map should immediately be facing your
   direction of travel, not north.
2. Rotate the phone a few degrees. The map should follow **continuously** — turn
   on the spot, without moving, and it should turn. A map that only re-orients when
   you take a step is a snapshot, not a mode.
3. Tap the compass in the HUD. The map should snap to true north, and the needle
   should stop following.
4. Tap again. It should return to heading-up.
5. Rotate the phone to landscape and back. The heading should stay correct; a map
   that only works in portrait has not read the interface orientation.
6. Leave navigation. The viewer should return to whatever mode it was in before —
   **unless** you tapped the compass during the hike, which is a choice and should
   survive.
7. In the viewer, on a **fresh install** (delete the app first, so location
   permission is asked again): tap **Locate** once to centre on yourself, then tap
   it again. The second tap should rotate the map to face your direction of
   travel, and it should keep following as you turn. A fresh grant is the path
   where authorisation returns through the callback that does not start heading
   updates — it is where the second tap used to find a dead stream and leave the
   map north-up forever.
8. Switch to another tab and back, then tap **Locate** twice again. Same rotation:
   the button stops its heading stream when it disappears, so this covers the
   other way the stream arrives dead.

**Pass:** step 2 tracks rotation without movement, step 3 is a true 0° (not
"approximately up"), step 6 respects a tap, and both viewer taps in steps 7-8
end up heading-up on a device — not merely centred.

**Why here:** the first heading is the one that matters and it cannot be tested
without a magnetometer. The device is also the only place a genuine 0° reset is
distinguishable from one that is nearly-north.

---

## 3. Icons

Visual pass, no pass/fail logic. Confirm these are distinct at arm's length:

- **Start navigation** (`figure.hiking`) in the toolbar
- **Locate** (`location.fill`) directly below it — the two used to be identical
- **Fit** (four corner brackets, the web app's glyph — was the `scope` reticle)
  in the left rail
- **Following / Pan freely** (`viewfinder.circle.fill` / `hand.raised.fill`) in the
  nav HUD
- **Missing key** (`key.slash.fill`), orange, when no key is configured

---

## 4. Search — needs a MapTiler key

Everything up to here works with no key. This and §5 do not, and both are the
first things in this list that cannot be verified at all without one.

1. Configure a key. With no key, search says **Search is unavailable** and that
   is correct — not a bug to file.
2. Search "Maroon Bells" from the **Create** tab. The sheet must appear. (The map
   screen's search button is gone for now: it never worked while the figures
   sheet is up — see [dev.md](dev.md).)
3. Confirm results arrive.
4. Turn **Slope shading** on from the map-type sheet and check the legend at the
   map's bottom right: the six bands, right colours, readable over the map.
5. Turn off location permission and search again. It should say so rather than
   return nothing.

**Pass:** the Create entry point presents, results actually arrive, and the
map's slope legend is correct with the shading on.

**Why here:** mostly because a key is needed — but note that "the sheet presents"
was also verified on the simulator. The part that needs a device is the real
round trip.

---

## 5. Elevation fill — needs a MapTiler key

1. Import a GPX that **has** elevations. Open it. The profile should draw from the
   file's own numbers, and Settings → Elevation → *Fill missing elevation* should
   be **off**.
2. Turn it on and reopen the route. The gaps between recorded points should gain
   detail.
3. Check that the recorded elevations did not move. They must not — this is a
   property of the fill, not a setting, and it is what makes the toggle safe.
4. Import a GPX with no elevations at all. With the fill off the chart is bare;
   with it on, the terrain model supplies the whole series.

**Why here:** no DEM access without a key. The "off by default" half *is*
checkable in the simulator and was checked there.

---

## 6. A key restricted to one user-agent

The failure this guards against is silent and lopsided: the map loads and
everything else quietly returns nothing.

1. In the MapTiler dashboard, restrict the key to the allowed user-agent
   `GPXNav (iOS; <your bundle id>)`.
2. Launch the app. **The map must still load.** If it does not, the allowlist value
   does not match — check the exact string, including the parentheses and spacing.
3. Do §4 and §5 again. Both must still work.

**Why here:** nothing about this is reachable from a simulator without a key, and
step 2 is the check that tells you whether the allowlist is right at all.

---

## 7. Hiking with the phone locked

The longest-standing unverified claim in the plan.

1. Grant **Always** location (the nav screen asks when navigation starts).
2. Start navigation and lock the phone.
3. Walk. Come back in two minutes.
4. Distance along, elapsed and pace should have advanced continuously, and the blue
   background indicator should have been on the whole time.

**Why here:** `simctl` cannot lock a phone, and the background indicator was only
ever observed on the simulator — where the screen is always on, so it proves less
than it appears to.

---

## 8. Airplane mode

1. Open a route, expand the sheet, tap **Download**, wait for *Available offline*.
2. Enable **Airplane Mode**.
3. Force-quit and relaunch, then pan and zoom inside the corridor.

Map and corridor both work; outside the corridor the basemap goes blank rather
than showing a cached tile from somewhere else.

**Why here:** the simulator shares the host's network and cannot really lose it.
This is the gate for the whole of §9 in the plan.

---

## Recording what happened

When a check passes here, the corresponding **Not verified** row in
[ios-plan.md](ios-plan.md) should be updated in the same PR. Those rows are the
only record of what has and has not actually been seen on hardware, and they are
worth exactly as much as the rigour behind them.