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
| **Identifies the client** | Exact `User-Agent` match, no prefix or substring |
| **Limits spend** | One Durable Object per client, per UTC day |
| **Forwards** | `/maps/`, `/tiles/`, `/geocoding/` — an allowlist, nothing else |
| **Does not cache** | See below. This is deliberate and it is the important part. |

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
curl -i -H "User-Agent: GPXNav (iOS; com.aelhamah.GPXNav)" \
  "https://<your-worker>/maps/outdoor-v2/style.json"
```

An unknown client gets `403` and **no upstream request at all** — that is the
property the tests spend most of their effort on, because it is the one whose
failure is invisible until somebody else's invoice arrives.

To exercise the Durable Object locally:

```bash
wrangler dev          # then curl the same two paths
```

## Wiring the app

Not in this PR — it cannot be tested until there is a Worker to test against.
Two changes when there is:

1. `MapTilerConfig` takes the proxy's base URL instead of `api.maptiler.com`,
   and stops putting the key in query strings.
2. The client keeps sending `MapNetworkIdentity.allowlistToken` unchanged. The
   Worker forwards that value upstream **byte for byte**, because the MapTiler
   key allowlist matches the whole header. Rewriting it at the proxy would break
   the restriction the proxy exists to make safe.

Until then the app talks to MapTiler directly and this Worker sits unused. That
is deliberate: a half-wired proxy is worse than none, because it looks like the
key problem is solved.

## Configuration

| Variable | Secret? | Meaning |
| --- | --- | --- |
| `MAPTILER_KEY` | **yes** | The MapTiler key |
| `ALLOWED_CLIENTS` | no | Comma-separated exact `User-Agent` values |
| `DAILY_QUOTA` | no | Requests per client per UTC day |
| `UPSTREAM` | no | Defaults to `https://api.maptiler.com` |
| `CACHE_TILES` | no | Absent = no caching. See §Enabling caching |
| `QUOTA` | — | Durable Object binding, one per client token |

`DAILY_QUOTA` defaults to 20,000, which is a runaway guard rather than a budget.
A client near it means the key is being shared or copied.

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