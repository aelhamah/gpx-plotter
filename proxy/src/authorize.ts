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

export type Authorization =
  | { allowed: true; token: string }
  | { allowed: false; status: 403 | 429; reason: 'no-user-agent' | 'unknown-client' | 'quota-exceeded' };

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

/** Authorize a request, given what the client presents and what they have spent. */
export function authorize(
  userAgent: string | null,
  allowed: readonly string[],
  quota: QuotaState,
  limit: number,
  today: string
): Authorization {
  const token = identifyClient(userAgent, allowed);
  if (!token) {
    // Distinguishing the two tells a developer whether to fix their User-Agent or
    // to be added to the list, which is the difference between a two-minute and a
    // two-hour support exchange. It leaks nothing: both answers are "no".
    return { allowed: false, status: 403, reason: userAgent ? 'unknown-client' : 'no-user-agent' };
  }
  if (!withinQuota(quota, limit, today)) {
    return { allowed: false, status: 429, reason: 'quota-exceeded' };
  }
  return { allowed: true, token };
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