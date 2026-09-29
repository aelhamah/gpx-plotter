# Getting the iOS app onto a physical device

A reference for the failure modes hit while installing GPXNav on a personal
iPhone, in the order they occur. The happy path is in
[dev.md → On a physical device](dev.md#on-a-physical-device); this file is what
to read when that path stops working.

The organising idea: every failure below looks like "Xcode can't sign", but they
are four unrelated problems — credentials, identity, pairing, and Developer Mode
— and they have to be cleared in order. Each stops you at a different stage, so
the error text tells you which one you are looking at.

## 0. Checklist

| # | Step | How to confirm |
|---|------|----------------|
| 1 | Apple ID signed in and fresh | `defaults read com.apple.dt.Xcode IDEProvisioningTeams` |
| 2 | Team id in `Secrets.local.xcconfig` | `grep DEVELOPMENT_TEAM ios/App/Secrets.local.xcconfig` |
| 3 | Computer trusted | `xcrun devicectl device info details` → `pairingState: paired` |
| 4 | Developer Mode on | same command → `developerModeStatus: enabled` |
| 5 | Project regenerated | `xcodegen generate` after any `project.yml` edit |
| 6 | Build, install, trust profile | xcodebuild, then trust under VPN & Device Management |

A fresh worktree or clone has no `GPXNav.xcodeproj` — it is generated and
gitignored, so `xcodebuild` fails with `does not exist` until you run
`xcodegen generate` from `ios/App`.

## 1. "Failed to retrieve development teams for <apple id>"

Seen in Xcode's signing UI, not necessarily as a build error. **The team almost
certainly exists** — the message means Xcode could not refresh the list. Confirm
before doing anything else:

```bash
defaults read com.apple.dt.Xcode IDEProvisioningTeams
```

```
{
    "alex.elhamahmy@gmail.com" = (
        { isFreeProvisioningTeam = 1; teamID = 9ZUZFHW3MH;
          teamName = "Alexander ElHamahmy (Personal Team)"; }
    );
}
```

The underlying cause is a stale Apple ID session, not a missing team:

```
[com.apple.accounts:core] "The connection to ACDAccountStore was invalidated."
[DVTAssertions:critical] <decode: missing data>
```

The account store is invalidated a few seconds after a *successful* sync, and
the empty team payload then decodes to nothing. Fix it in this order, quitting
Xcode fully (⌘Q) between each step — a running Xcode will not re-authenticate
in place:

1. Settings → Accounts → select the account → **Remove Account**
2. ⌘Q, reopen Xcode
3. Settings → Accounts → **+** → Apple ID, sign in with the **full password**
   (2FA code ready)
4. If the password is rejected, reset it at <https://iforgot.apple.com> first.
   A stale password is the usual reason Xcode reports the details as rejected
   even when they are correct.

### One Apple ID, two team ids

Free Personal Teams are per-account, so two Apple IDs signed into the same Mac
give two different team ids, and it is easy to copy the wrong one:

| Account | Team id |
|---------|---------|
| `alex.elhamahmy@gmail.com` | `9ZUZFHW3MH` |
| `aelhamah@umich.edu` | `C39Z862JD3` |

Read the id out of `defaults` rather than trusting memory or
`IDEProvisioningTeamManagerLastSelectedTeamID` — the latter is only the last
clicked team and can belong to either account.

## 2. "Unable to log in with account … login details were rejected"

The same stale session as §1, surfaced at build time, because `xcodebuild` makes
its own authenticated call rather than reusing Xcode's. It is usually followed
by a second error that looks like the real one but is not:

```
error: Unable to log in with account 'alex.elhamahmy@gmail.com'.
error: No profiles for 'com.example.GPXNav' were found
```

**The "no profiles" error is a consequence.** It means the machine has never
provisioned anything, so once the credentials are rejected, xcodebuild has no
profile to fall back on. Check with:

```bash
ls ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/   # absent if never provisioned
security find-identity -v -p codesigning                       # 0 valid identities if no cert
```

On a machine that has never built to a device the directory is missing and the
count is `0`; once provisioning succeeds, both fill in. Fix the login and the
profile is created automatically — do not go hunting for one in the developer
portal.

`defaults read com.apple.dt.Xcode` showing *no* `IDEProvisioningTeamIdentifiers`
key is normal on a fresh machine and is not a symptom.

## 3. "Unable to find a device matching the provided destination specifier"

Paired status, not a signing problem:

```
error: Alex's iPhone is not available because it is unpaired.
       Pair with the device in the Xcode Devices Window,
       and respond to any pairing prompts on the device.
```

Tap **Trust This Computer** on the phone and enter its passcode. If the prompt
has already been dismissed, unlock the phone and it will reappear. Confirm with:

```bash
xcrun devicectl device info details --device <id> | grep pairingState
```

### Two different device ids

`devicectl` and `xcodebuild` identify the same phone differently, and the
`devicectl` id fails the destination lookup:

```bash
# coredevice id — works with devicectl
xcrun devicectl list devices
#   ED8D3342-A34B-52F0-B012-85AD0AF40BB3

# hardware udid — required by -destination
xcodebuild -destination 'platform=iOS,id=00008130-001945C93011401C'
```

Both appear in the error text, so read it rather than assuming either is wrong.

## 4. "Developer Mode disabled"

```
error: Developer Mode disabled
       To enable, go to Settings → Privacy & Security
```

On the phone: **Settings → Privacy & Security → Developer Mode** → on →
confirm → **restart the device**. The restart is required, and until it happens
the status stays `disabled`:

```bash
xcrun devicectl device info details --device <id> | grep developerModeStatus
```

This is also the answer to "do I need to trust a cert on my phone?" — yes, but
this is a separate step from both pairing (§3) and the developer profile (§5),
and enabling Developer Mode first means you only do the trust dance once.

## 5. Trusting the developer profile after the first install

The install succeeds and the app is on the phone, but the **first launch is
refused** until the profile is trusted. `devicectl` puts it plainly:

```
error: Unable to launch com.example.GPXNav because it has an invalid code
signature, inadequate entitlements or its profile has not been explicitly
trusted by the user.
  FBSOpenApplicationErrorDomain error 3 (0x03)
  BSErrorCodeDescription = Security
```

Read the wording carefully: it names three causes, and only the third is
applicable to a build that just succeeded. An invalid signature or inadequate
entitlements would be a real packaging fault, but a green signed build rules
those out — this is the trust prompt, and the first two are just the message
hedging.

**Settings → General → VPN & Device Management → Apple Development: <name> →
Trust**

Nothing to do on the Mac, and no rebuild needed — the installed app is fine.
Trusting is per-app, so it survives reinstalls but not a wiped device or a new
certificate. If the entry is missing from that list, the app did not install
and the problem is earlier in this list.

The symptom is a tap that has to happen once per certificate, which is why
enabling Developer Mode (§4) first is worth the restart: otherwise you trust
the computer, then discover Developer Mode, then build and install, and only
then find out there is a second trust to do.

## 6. Signing succeeds but every map request fails

Nothing to do with the build — the bundle id is part of the MapTiler allowlist:

```
[MapNetworkIdentity] allowlist this on the MapTiler key: GPXNav (iOS; com.example.GPXNav)
```

The user-agent is assembled from `Bundle.main.bundleIdentifier` at runtime
(`ios/App/GPXNav/Map/MapNetworkIdentity.swift`). **Changing the bundle id
changes the allowlist token**, and the key then returns `403 Key usage
restricted` for tiles, DEM and geocoding alike. Either keep
`com.example.GPXNav` or add the new string to the key's allowed origins. The
app logs the exact token on launch — read it rather than reconstructing it.

## Checks worth knowing are misleading

- **`xcodebuild -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
  build`** compiles the whole app for device without signing. A green result
  rules out every compile, architecture and dependency problem, leaving signing
  as the only unknown. Useful for isolating §1–§2 from real code breakage.
- **`xcrun devicectl --version`** — if absent, the Xcode command line tools are
  wrong; `devicectl` ships with Xcode 15+.
- **Network reachability is not the cause.** `curl https://developer.apple.com`
  returning `200` rules out basic connectivity but says nothing about the
  authenticated team call, which is what actually fails in §1. Testing
  connectivity will send you down a dead end.
- **The empty `GPXNavWidgets` target cannot block an install.** It has no
  sources and no `NSExtension` plist, but it is not embedded in the app bundle
  (no `PlugIns/` in the built `.app`) and the `GPXNav` scheme does not build it,
  so it needs no team and is not part of the install.

## Expiry: the 7-day trap

A free Personal Team's provisioning profile **expires 7 days after it is
created**. Symptoms: the app installs, runs, then refuses to launch and Xcode
reports a signing or profile error on the next build. It is not a code problem —
rebuild and reinstall:

```bash
xcodebuild -project GPXNav.xcodeproj -scheme GPXNav \
  -destination 'platform=iOS,id=<hardware-udid>' \
  -allowProvisioningUpdates build
```

A paid account gets a year, and also removes the per-machine restriction on
Personal Teams. For testing that needs to outlive a week, that is the
difference between a device check and TestFlight.

## Offline testing on device

The device check that the simulator cannot satisfy, since the simulator shares
the host's network and cannot really lose it:

1. Open a route, expand the sheet, tap **Download**, wait for *Available offline*
2. Enable **Airplane Mode**
3. Force-quit and relaunch, then pan and zoom inside the corridor

The tile cache is per-device, so a fresh install starts empty — nothing carries
over from the simulator. See `docs/dev.md` for the cache inspection commands and
the launch arguments (`-downloadOffline` and friends), which work on device via
the scheme's arguments in Xcode.
