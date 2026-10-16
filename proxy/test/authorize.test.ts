import { describe, expect, it } from 'vitest';
import { authorize, countRequest, identifyClient, withinQuota, type QuotaState } from '../src/authorize';

const TOKEN = 'GPXNav (iOS; com.aelhamah.GPXNav)';
const OTHER = 'GPXNav (iOS; com.example.SomeoneElse)';
const TODAY = '2026-10-16';
const YESTERDAY = '2026-10-15';

describe('identifyClient', () => {
  it('accepts an exact token', () => {
    expect(identifyClient(TOKEN, [TOKEN])).toBe(TOKEN);
  });

  /**
   * The whole security property. A substring or prefix match would accept clients
   * that the upstream key rejects, which produces the worst available outcome:
   * the proxy spends the key on a request MapTiler then refuses.
   */
  it('rejects a token that merely starts the same way', () => {
    expect(identifyClient(`${TOKEN} MapLibre/6.31.0`, [TOKEN])).toBeNull();
  });

  it('rejects a token with trailing junk', () => {
    expect(identifyClient(`${TOKEN} curl/8.0`, [TOKEN])).toBeNull();
  });

  it('rejects a different app entirely', () => {
    expect(identifyClient(OTHER, [TOKEN])).toBeNull();
  });

  it('rejects a missing header', () => {
    expect(identifyClient(null, [TOKEN])).toBeNull();
  });

  it('rejects an empty header', () => {
    expect(identifyClient('', [TOKEN])).toBeNull();
  });

  /**
   * A version suffix is exactly the "harmless improvement" that breaks a key at
   * release time, so the one place it could creep in is pinned.
   */
  it('tolerates surrounding whitespace, because proxies add it', () => {
    expect(identifyClient(`  ${TOKEN}  `, [TOKEN])).toBe(TOKEN);
  });

  it('rejects everything when no clients are allowlisted', () => {
    expect(identifyClient(TOKEN, [])).toBeNull();
  });
});

describe('withinQuota', () => {
  const state = (count: number, day = TODAY): QuotaState => ({ day, count });

  it('allows anything under the limit', () => {
    expect(withinQuota(state(0), 10, TODAY)).toBe(true);
    expect(withinQuota(state(9), 10, TODAY)).toBe(true);
  });

  it('refuses the request that would exceed the limit', () => {
    expect(withinQuota(state(10), 10, TODAY)).toBe(false);
    expect(withinQuota(state(11), 10, TODAY)).toBe(false);
  });

  /** A calendar day, not a rolling 24 hours. See the note in authorize.ts. */
  it('resets on a new day', () => {
    expect(withinQuota(state(9999, YESTERDAY), 10, TODAY)).toBe(true);
  });

  it('refuses everything at a zero limit', () => {
    expect(withinQuota(state(0), 0, TODAY)).toBe(false);
  });
});

describe('countRequest', () => {
  it('increments within a day', () => {
    expect(countRequest({ day: TODAY, count: 4 }, TODAY)).toEqual({ day: TODAY, count: 5 });
  });

  it('starts a fresh count on a new day', () => {
    expect(countRequest({ day: YESTERDAY, count: 999 }, TODAY)).toEqual({ day: TODAY, count: 1 });
  });

  it('is what makes the boundary correct end to end', () => {
    let state: QuotaState = { day: TODAY, count: 0 };
    let served = 0;
    for (let i = 0; i < 25; i += 1) {
      if (!withinQuota(state, 10, TODAY)) break;
      served += 1;
      state = countRequest(state, TODAY);
    }
    expect(served).toBe(10);
    expect(state.count).toBe(10);
  });
});

describe('authorize', () => {
  const fresh: QuotaState = { day: TODAY, count: 0 };

  it('allows an allowlisted client inside its quota', () => {
    expect(authorize(TOKEN, [TOKEN], fresh, 10, TODAY)).toEqual({ allowed: true, token: TOKEN });
  });

  it('refuses an unknown client with 403', () => {
    expect(authorize(OTHER, [TOKEN], fresh, 10, TODAY)).toEqual({
      allowed: false,
      status: 403,
      reason: 'unknown-client',
    });
  });

  it('tells a missing header apart from an unknown one', () => {
    const result = authorize(null, [TOKEN], fresh, 10, TODAY);
    expect(result).toEqual({ allowed: false, status: 403, reason: 'no-user-agent' });
  });

  it('refuses an allowlisted client that is over quota with 429', () => {
    expect(authorize(TOKEN, [TOKEN], { day: TODAY, count: 10 }, 10, TODAY)).toEqual({
      allowed: false,
      status: 429,
      reason: 'quota-exceeded',
    });
  });

  /** Identity is checked first, so an unknown client is refused even over quota. */
  it('never spends quota on a client it would refuse anyway', () => {
    expect(authorize(OTHER, [TOKEN], { day: TODAY, count: 10 }, 10, TODAY)).toMatchObject({
      status: 403,
      reason: 'unknown-client',
    });
  });

  it('returns the exact token, so the caller forwards it unchanged', () => {
    const result = authorize(TOKEN, [TOKEN], fresh, 10, TODAY);
    expect(result.allowed && result.token).toBe(TOKEN);
  });
});