// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { LOADING_TEXT, MapLoading, REVEAL_AFTER_MS, SLOW_TEXT } from '../src/mapLoading';

// Deliberately short thresholds so the tests read as behaviour ("loading longer
// than the reveal delay") rather than as arithmetic against constants.
const REVEAL = 100;
const HINT = 1_000;

function makeIndicator() {
  const element = document.createElement('div');
  element.className = 'map-loader hidden';
  document.body.append(element);
  return { element, loading: new MapLoading(element, REVEAL, HINT) };
}

describe('MapLoading', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
    document.body.innerHTML = '';
  });

  it('says nothing for a load that finishes inside the reveal delay', () => {
    const { element, loading } = makeIndicator();

    loading.beginLoading();
    vi.advanceTimersByTime(REVEAL - 1);
    expect(element.classList.contains('hidden')).toBe(true);
    expect(element.textContent).toBe('');

    vi.advanceTimersByTime(1);
    expect(loading.visible).toBe(true);
    expect(element.textContent).toBe(LOADING_TEXT);
  });

  /**
   * The property the whole delay exists for. `dataloading` fires on every pan,
   * zoom and style swap, and most settle in tens of milliseconds — an indicator
   * that appeared on each would be a flicker on a map the user is actively using.
   */
  it('never appears for the many short loads of ordinary use', () => {
    const { element, loading } = makeIndicator();

    for (let pan = 0; pan < 20; pan += 1) {
      loading.beginLoading();
      vi.advanceTimersByTime(30);
      loading.endLoading();
    }

    expect(element.classList.contains('hidden')).toBe(true);
    expect(element.textContent).toBe('');
  });

  it('appears when loading outlasts the reveal delay', () => {
    const { loading } = makeIndicator();

    loading.beginLoading();
    vi.advanceTimersByTime(REVEAL);

    expect(loading.visible).toBe(true);
  });

  it('says the connection is the slow part once the wait is long', () => {
    const { element, loading } = makeIndicator();

    loading.beginLoading();
    vi.advanceTimersByTime(REVEAL);
    expect(element.textContent).toBe(LOADING_TEXT);

    vi.advanceTimersByTime(HINT);
    expect(element.textContent).toBe(SLOW_TEXT);
  });

  /**
   * A spinner alone is indistinguishable from a hang, which is the other way a
   * slow load reads as a broken page — so the message has to change, not just the
   * spinner keep turning.
   */
  it('never claims a service has failed while it is still loading', () => {
    const { element, loading } = makeIndicator();

    loading.beginLoading();
    vi.advanceTimersByTime(REVEAL + HINT);

    expect(element.textContent).not.toMatch(/fail|error|won't load/i);
  });

  it('hides once the map goes idle', () => {
    const { element, loading } = makeIndicator();

    loading.beginLoading();
    vi.advanceTimersByTime(REVEAL + HINT);
    expect(loading.visible).toBe(true);

    loading.endLoading();

    expect(loading.visible).toBe(false);
    expect(element.textContent).toBe('');
  });

  /**
   * MapLibre fires `dataloading` for every tile it wants while a slow load is
   * still running. Re-arming the reveal on each would push it back forever, and
   * the indicator would never appear at all — the exact failure this exists to
   * fix.
   */
  it('does not re-arm the reveal while a slow load is already counted', () => {
    const { element, loading } = makeIndicator();

    loading.beginLoading();
    vi.advanceTimersByTime(REVEAL / 2);
    loading.beginLoading();
    vi.advanceTimersByTime(REVEAL / 2);

    expect(element.classList.contains('hidden')).toBe(false);
    expect(element.textContent).toBe(LOADING_TEXT);
  });

  it('treats further loading calls after a repeat as part of the same load', () => {
    const { element, loading } = makeIndicator();

    loading.beginLoading();
    vi.advanceTimersByTime(REVEAL);
    for (let tile = 0; tile < 50; tile += 1) {
      loading.beginLoading();
      vi.advanceTimersByTime(10);
    }

    // Still the plain message: the repeat calls must not reset the hint clock
    // either, or a load that keeps trickling tiles never gets past "Loading map…".
    expect(element.textContent).toBe(LOADING_TEXT);
    vi.advanceTimersByTime(HINT);
    expect(element.textContent).toBe(SLOW_TEXT);
  });

  /** Swapping basemaps is a fresh load, and must be covered like the first one. */
  it('re-arms for a load that starts after one finished', () => {
    const { element, loading } = makeIndicator();

    loading.beginLoading();
    vi.advanceTimersByTime(REVEAL);
    loading.endLoading();
    expect(loading.visible).toBe(false);

    loading.beginLoading();
    vi.advanceTimersByTime(REVEAL);

    expect(loading.visible).toBe(true);
    expect(element.textContent).toBe(LOADING_TEXT);
  });

  /**
   * A failed style never reaches `idle`, so without `fail()` the spinner would
   * turn forever beside a banner already naming the dead service.
   */
  it('stands down for the service banner when the style fails', () => {
    const { element, loading } = makeIndicator();

    loading.beginLoading();
    vi.advanceTimersByTime(REVEAL + HINT);
    expect(loading.visible).toBe(true);

    loading.fail();

    expect(loading.visible).toBe(false);
    expect(element.textContent).toBe('');
  });

  it('drops its pending timers when a load stands down', () => {
    const { element, loading } = makeIndicator();

    loading.beginLoading();
    loading.fail();
    vi.advanceTimersByTime(REVEAL + HINT);

    expect(element.classList.contains('hidden')).toBe(true);
    expect(element.textContent).toBe('');
  });

  it('leaves nothing running after destroy', () => {
    const { element, loading } = makeIndicator();

    loading.beginLoading();
    loading.destroy();
    vi.advanceTimersByTime(REVEAL + HINT);

    expect(element.classList.contains('hidden')).toBe(true);
    expect(element.textContent).toBe('');
    expect(vi.getTimerCount()).toBe(0);
  });

  /** A stuck spinner is worse than no spinner, so the class must never leak one. */
  it('always leaves the element hidden when nothing is loading', () => {
    const { element, loading } = makeIndicator();

    expect(loading.visible).toBe(false);

    loading.beginLoading();
    loading.endLoading();
    loading.beginLoading();
    loading.fail();
    loading.destroy();

    expect(loading.visible).toBe(false);
    expect(element.textContent).toBe('');
  });

  it('defaults to delays that tolerate ordinary network latency', () => {
    expect(REVEAL_AFTER_MS).toBeGreaterThanOrEqual(250);
    expect(REVEAL_AFTER_MS).toBeLessThan(1_000);
  });
});