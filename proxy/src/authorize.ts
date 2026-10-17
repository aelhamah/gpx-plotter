/**
 * Who is allowed to spend the key, and how much.
 *
 * These are pure functions on purpose. Everything that decides whether a request
 * is served, refused or delayed lives here rather than in the Worker entry
 * point, because this is the part where a mistake hands somebody else's MapTiler
 * bill to us, and it should be testable without a Cloudflare runtime, a network,
 * or an account.
 */

/** One day's usage for one client. */
export interface QuotaState {
  /** `YYYY-MM-DD` in UTC. */
  day: string;
  count: number;
}

/**
 * How a caller identified itself.
 *
 * Two mechanisms, because the two clients are not alike:
 *
 * - `native` — the iOS app, which sets its own `User-Agent` freely.
 * - `web` — the browser build, which cannot. `User-Agent` is a forbidden header
 *   name in `fetch`/XHR, so a browser can only ever present whatever the
 *   browser decided to send, and no amount of care in the app changes that.
 *
 * ## What an `Origin` check is and is not
 *
 * It is **not** a secret. `curl -H "Origin: https://aelhamah.github.io"` sets it
 * as freely as a native client sets a `User-Agent`, so neither mechanism stops
 * somebody who has decided to take the key. What they actually buy:
 *
 * - the key stays out of the shipped bundle, which is where the passive leak was;
 * - every deployment and every user lands in a named quota bucket with a bill
 *   attached, so abuse is attributable instead of anonymous;
 * - the cap is enforceable, and the cap is what stops one client spending the
 *   account.
 *
 * That is a real improvement on an origin-restricted browser key — which anyone
 * can read out of the bundle — but it is not a lock, and the README should not
 * describe it as one.
 */
export type ClientKind = 'native' | 'web';

/** The exact header values that may spend the key. */
export interface ClientPolicy {
  /** Exact `User-Agent` values, native clients. */
  userAgents: readonly string[];
  /** Exact `Origin` values, browser clients. */
  origins: readonly string[];
}

export type Authorization =
  | { allowed: true; kind: ClientKind; token: string }
  | { allowed: false; status: 403 | 429; reason: 'no-credentials' | 'unknown-client' | 'quota-exceeded' };

/**
 * The exact `User-Agent` value a client must present.
 *
 * Exact, and not a prefix or a substring, for the reason the app's
 * `MapNetworkIdentity` gives: MapTiler matches the whole header when an
 * allowlist is a plain string, so a loose comparison here would accept clients
 * the upstream key rejects, and produce the worst outcome available — the map
 * loads and everything else quietly fails.
 *
 * Returns the token rather than a boolean so the caller forwards *that exact
 * string* upstream. Rewriting it would break the MapTiler allowlist.
 */
export function identifyClient(userAgent: string | null, allowed: readonly string[]): string | null {
  if (!userAgent) return null;
  const trimmed = userAgent.trim();
  return allowed.includes(trimmed) ? trimmed : null;
}

/**
 * The exact `Origin` value a browser must present.
 *
 * Exact, and for the same reason as the user-agent above: a prefix match would
 * happily accept `https://aelhamah.github.io.evil.test`, which is a different
 * site that happens to start with the same characters.
 *
 * An `Origin` is `scheme://host[:port]` with no trailing slash and no path, so
 * this compares whole values and nothing needs normalising — which is also why
 * the allowlist has to list the port explicitly for `http://localhost:5173`.
 */
export function identifyOrigin(origin: string | null, allowed: readonly string[]): string | null {
  if (!origin) return null;
  const trimmed = origin.trim();
  return allowed.includes(trimmed) ? trimmed : null;
}

/**
 * Identify the caller by whichever mechanism it can actually use.
 *
 * The user-agent is tried first so that a native client keeps being recognised
 * as native even if something in front of it adds an `Origin` header — which a
 * captive portal or an enterprise proxy can easily do, and which would
 * otherwise misfile the app's traffic into the browser's shared allowance.
 */
export function identifyCaller(
  userAgent: string | null,
  origin: string | null,
  policy: ClientPolicy
): { kind: ClientKind; token: string } | null {
  const native = identifyClient(userAgent, policy.userAgents);
  if (native) return { kind: 'native', token: native };
  const web = identifyOrigin(origin, policy.origins);
  if (web) return { kind: 'web', token: web };
  return null;
}

/** Authorize a request, given what the client presents and what they have spent. */
export function authorize(
  userAgent: string | null,
  origin: string | null,
  policy: ClientPolicy,
  quota: QuotaState,
  limit: number,
  today: string
): Authorization {
  const caller = identifyCaller(userAgent, origin, policy);
  if (!caller) {
    // Distinguishing "you sent nothing" from "you sent something we do not
    // recognise" tells a developer whether to fix their configuration or to be
    // added to a list, which is the difference between a two-minute and a
    // two-hour support exchange. It leaks nothing: both answers are "no".
    const silent = !userAgent && !origin;
    return { allowed: false, status: 403, reason: silent ? 'no-credentials' : 'unknown-client' };
  }
  if (!withinQuota(quota, limit, today)) {
    return { allowed: false, status: 429, reason: 'quota-exceeded' };
  }
  return { allowed: true, kind: caller.kind, token: caller.token };
}

/**
 * Whether the next request is inside the day's allowance.
 *
 * A new UTC day resets it. Resetting on the *stored* day rather than on a
 * timestamp is deliberate: a Durable Object that dies mid-day comes back with no
 * memory, and a rolling 24-hour window would then hand out a second full
 * allowance. A calendar day fails that way by giving slightly less, never more.
 */
export function withinQuota(quota: QuotaState, limit: number, today: string): boolean {
  if (quota.day !== today) return true;
  return quota.count < limit;
}

/** The state after counting one more request. */
export function countRequest(quota: QuotaState, today: string): QuotaState {
  return quota.day === today ? { day: today, count: quota.count + 1 } : { day: today, count: 1 };
}