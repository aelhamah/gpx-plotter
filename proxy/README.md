# Tile proxy

A Cloudflare Worker that sits in front of MapTiler so the API key does not ship
inside the app bundle.

The key is currently a string in `MapTilerConfig`. Anyone can download the
`.ipa`, read it out, and spend the account. This moves the key into a Worker
secret and hands out the Worker's URL instead.

## What it does

| | |
| --- | --- |
| **Holds the key** | In `wrangler` secrets, never in the app and never in this repo |
| **Identifies the client** | Exact match on `User-Agent` (native) or `Origin` (browser) |
| **Limits spend** | One Durable Object per client, per UTC day, separately per kind |
| **Forwards** | `/maps/`, `/tiles/`, `/geocoding/` — an allowlist, nothing else |
| **Does not cache** | See below. This is deliberate and it is the important part. |

## Two callers, two ways of proving who you are

| | Native app | Browser build |
| --- | --- | --- |
| Identified by | exact `User-Agent` | exact `Origin` |
| Leaves as | the allowlisted `User-Agent` | the same allowlisted `User-Agent` |
| Allowance | `DAILY_QUOTA` | `WEB_DAILY_QUOTA` |
| CORS | not applicable — `NSURLSession` sends no `Origin` | `Access-Control-Allow-Origin` echoed |

The native app can set `User-Agent` freely, so that is what it uses. The browser
cannot: `User-Agent` is a forbidden header name, so a page can only ever present
what the browser decided to send. `Origin` is the header it *can* be judged on.

Both leave upstream wearing the same `User-Agent`, because the MapTiler key's own
allowlist is one exact string and keeping it that way is what allows the key to
exist in no client at all.

### What an `Origin` check is not

**It is not a secret.** `curl -H "Origin: https://aelhamah.github.io"` sets it as
freely as a native client sets a `User-Agent`. Neither mechanism stops somebody
who has decided to take the key.

What they buy, over an origin-restricted browser key sitting in a public bundle:

- the key is not in the shipped JavaScript at all, so there is nothing to read
  out of it;
- every deployment gets a named, capped, attributable quota bucket;
- the cap is enforceable, and the cap is what stops one client spending the
  account.

### Why CORS is handled here at all

`curl` has no origin policy. A browser will discard any response that does not
say it may be read, so without `Access-Control-Allow-Origin` the tile is
fetched, dropped, and the map is blank. It is also why refusals carry the header:
a browser cannot read the `429 quota_exceeded` that explains what happened, and
the user gets an unexplained CORS error instead.

It is echoed for a *verified* origin, never `*` — a wildcard would make the
proxy readable by every page on the internet, which is the opposite of an origin
allowlist. `Vary: Origin` is set on every response, because a shared cache in
front of this Worker must not hand one allowlisted origin's response to another.

## It does not cache, on purpose

MapTiler's terms prohibit bulk tile downloading without a written agreement.
**Caching tile bodies at the edge is bulk downloading** — the request pattern is
indistinguishable from scraping, which is what the clause exists to prevent.

So the default configuration forwards a request, forgets it, and returns
`Cache-Control: no-store` plus `X-Proxy-Cache: disabled`. That is useful *today*,
under the terms as they stand: the key stops leaking, the bill stops being
open-ended, and nothing about MapTiler's terms changes.

It does not get you offline. **Offline is a separate decision** — see §Offline.

### Enabling caching later

Only once MapTiler has agreed in writing. Then:

```bash
wrangler secret put CACHE_TILES   # value: true
```

That is the entire change. It is a flag rather than an absent line of code so
that turning it on is a deliberate act with a date and a permission attached,
instead of a `caches.default.match` appearing during an optimisation.

The flag is covered by tests in **both** directions — the default really does
skip the cache, and the enabled path really does write to it — because a switch
nobody has ever run is a switch that throws in production at the moment someone
starts relying on it.

## Offline

The app's corridor download (§9 of [../docs/ios-plan.md](../docs/ios-plan.md))
fetches tiles and stores them on the user's device. That is the feature this
proxy deliberately does not enable, and no version of it can: bulk downloading
is a licensing question, not an engineering one.

Three ways forward, none of which this Worker decides:

1. **Ask MapTiler** for a written exception. Cheapest if they say yes.
2. **On-Prem Standard** — legal for redistribution, forbids public-cloud
   hosting, so this Worker would have to be replaced by something you host.
3. **Self-host** OSM tiles and terrain. Fully legal, and the geocoder needs
   replacing too.

## Deploying

```bash
npm install
wrangler secret put MAPTILER_KEY      # the MapTiler key; never in a file
wrangler deploy
```

Check it:

```bash
curl -i https://<your-worker>/__health

# Native: exact User-Agent
curl -i -H "User-Agent: GPXNav (iOS; com.aelhamah.GPXNav)" \
  "https://<your-worker>/maps/outdoor-v2/style.json"

# Browser: exact Origin, and the CORS header must come back with it
curl -i -H "Origin: https://aelhamah.github.io" \
  "https://<your-worker>/maps/outdoor-v2/style.json"
```

A browser that gets a `200` with no `access-control-allow-origin` will discard
the response and show a blank map, so check that header as well as the status.

An unknown client gets `403` and **no upstream request at all** — that is the
property the tests spend most of their effort on, because it is the one whose
failure is invisible until somebody else's invoice arrives.

To exercise the Durable Object locally:

```bash
wrangler dev          # then curl the same two paths
```

## Wiring the app

Both clients are wired. What each one needs to be told:

**Native** — the proxy's base URL, in place of the MapTiler key:

```
TILE_PROXY_SCHEME = https
TILE_PROXY_HOST    = gpxnav-tile-proxy.gpxnav.workers.dev
```

in `ios/App/Secrets.local.xcconfig`, which `project.yml` rejoins into the
`TileProxyBaseURL` Info.plist entry. Split into two halves because **xcconfig
reads `//` as the start of a comment**: `TILE_PROXY_BASE_URL = https://host`
silently resolves to `https:`, and quoting does not help. The app then falls
back to MapLibre's demo basemap with nothing on screen to explain why.

`MapNetworkIdentity.allowlistToken` is unchanged and still sent byte for byte —
the Worker forwards it upstream exactly as received, because the MapTiler key
allowlist matches the whole header. Rewriting it at the proxy would break the
restriction the proxy exists to make safe.

**Web** — the same URL, from `VITE_TILE_PROXY_BASE_URL` in `web/.env.local` and
in CI. `src/config.ts` builds every MapTiler URL from it and carries no key.

**For local development against a Worker running on your machine**, use
`http://127.0.0.1:8787` with `npx wrangler dev`, and add the origin you are
serving from to `ALLOWED_ORIGINS`. ATS already permits loopback HTTP for the
native app via `NSAllowsLocalNetworking`, and `http://127.0.0.1` is a secure
context for the browser.

## Configuration

| Variable | Secret? | Meaning |
| --- | --- | --- |
| `MAPTILER_KEY` | **yes** | The MapTiler key |
| `ALLOWED_CLIENTS` | no | Comma-separated exact `User-Agent` values |
| `ALLOWED_ORIGINS` | no | Comma-separated exact `Origin` values the browser may use |
| `DAILY_QUOTA` | no | Requests per native client per UTC day |
| `WEB_DAILY_QUOTA` | no | Requests per *origin* per UTC day. Defaults to `DAILY_QUOTA` |
| `UPSTREAM` | no | Defaults to `https://api.maptiler.com` |
| `CACHE_TILES` | no | Absent = no caching. See §Enabling caching |
| `QUOTA` | — | Durable Object binding, one per client token |

`DAILY_QUOTA` defaults to 20,000, which is a runaway guard rather than a budget.
A client near it means the key is being shared or copied.

`WEB_DAILY_QUOTA` is separate and much larger because it has to be: every
browser user of a deployment shares one bucket, since there is no stable
per-visitor identity a browser can be asked for, and a single map view is a few
hundred requests. Sharing the native figure would have that allowance gone in
minutes.

`ALLOWED_ORIGINS` is matched exactly, never by prefix:
`https://aelhamah.github.io.evil.test` starts with an allowlisted value and is a
different site. Scheme, host and port are all part of an origin, so the Vite dev
server needs its own entries and the port is not optional.

Changing an origin means editing `ALLOWED_ORIGINS` *and* reloading. A deploy
that accepts an origin nobody allowed is a deploy serving anyone.

## Tests

```bash
npm test        # 50 tests
npm run typecheck
```

They are written against Node rather than a Cloudflare runtime, deliberately: the
decisions that matter — who is allowed, how much, what may be forwarded, and
whether the key can escape — are pure functions and a stubbed network away. The
one thing not covered locally is the Durable Object's own storage round trip, so
`wrangler dev` is still worth a pass before deploying.