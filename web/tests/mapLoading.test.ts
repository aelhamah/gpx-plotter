// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  BACKGROUND_REVEAL_AFTER_MS,
  BACKGROUND_SLOW_TEXT,
  INITIAL_REVEAL_AFTER_MS,
  INITIAL_SLOW_TEXT,
  INITIAL_TEXT,
  MapLoading,
} from '../src/mapLoading';

// Deliberately short thresholds so the tests read as behaviour ("loading longer
// than the reveal delay") rather than as arithmetic against constants.
const INITIAL = 100;
const BACKGROUND = 300;
const HINT = 1_000;

function makeIndicator() {
  const element = document.createElement('div');
  element.className = 'map-loader hidden';
  document.body.append(element);
  return {
    element,
    loading: new MapLoading(element, {
      initialRevealAfterMs: INITIAL,
      backgroundRevealAfterMs: BACKGROUND,
      hintAfterMs: HINT,
    }),
  };
}

/** Drive one first load through to idle, leaving `loading` in its background state. */
function completeFirstLoad(loading: MapLoading) {
  loading.beginLoading();
  vi.advanceTimersByTime(INITIAL + HINT);
  loading.endLoading();
}

describe('MapLoading', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
    document.body.innerHTML = '';
  });

  describe('the first load', () => {
    it('is centred, worded, and says nothing until the delay is out', () => {
      const { element, loading } = makeIndicator();

      loading.beginLoading();
      vi.advanceTimersByTime(INITIAL - 1);
      expect(loading.visible).toBe(false);
      expect(element.classList.contains('hidden')).toBe(true);

      vi.advanceTimersByTime(1);
      expect(loading.mode).toBe('initial');
      expect(element.classList.contains('map-loader-corner')).toBe(false);
      expect(element.textContent).toBe(INITIAL_TEXT);
    });

    it('says the connection is the slow part once the wait is long', () => {
      const { element, loading } = makeIndicator();

      loading.beginLoading();
      vi.advanceTimersByTime(INITIAL);
      expect(element.textContent).toBe(INITIAL_TEXT);

      vi.advanceTimersByTime(HINT);
      expect(element.textContent).toBe(INITIAL_SLOW_TEXT);
    });

    /**
     * A spinner alone is indistinguishable from a hang, which is the other way a
     * slow load reads as a broken page — so the message has to change, not just the
     * spinner keep turning.
     */
    it('never claims a service has failed while it is still loading', () => {
      const { element, loading } = makeIndicator();

      loading.beginLoading();
      vi.advanceTimersByTime(INITIAL + HINT);

      expect(element.textContent).not.toMatch(/fail|error|won't load/i);
    });

    it('hides once the map goes idle', () => {
      const { element, loading } = makeIndicator();

      loading.beginLoading();
      vi.advanceTimersByTime(INITIAL + HINT);
      expect(loading.visible).toBe(true);

      loading.endLoading();

      expect(loading.visible).toBe(false);
      expect(loading.mode).toBeNull();
      expect(element.classList.contains('hidden')).toBe(true);
      expect(element.textContent).toBe('');
    });
  });

  describe('every load after the first', () => {
    it('goes to the corner rather than the middle', () => {
      const { element, loading } = makeIndicator();
      completeFirstLoad(loading);

      loading.beginLoading();
      vi.advanceTimersByTime(BACKGROUND);

      expect(loading.mode).toBe('background');
      expect(element.classList.contains('map-loader-corner')).toBe(true);
    });

    /**
     * The reason it is in a corner at all. A zoom is something the user just did,
     * and a centred pill reporting it back at them lands on the thing they were
     * zooming towards. An indicator that appears on every zoom also trains people
     * to ignore it, so the first load — the one that matters — gets ignored too.
     */
    it('is silent for a pan quick enough to be unremarkable', () => {
      const { element, loading } = makeIndicator();
      completeFirstLoad(loading);

      loading.beginLoading();
      vi.advanceTimersByTime(BACKGROUND - 1);

      expect(loading.visible).toBe(false);
      expect(element.textContent).toBe('');
    });

    it('is a bare dot with no words once it does appear', () => {
      const { element, loading } = makeIndicator();
      completeFirstLoad(loading);

      loading.beginLoading();
      vi.advanceTimersByTime(BACKGROUND);

      expect(loading.visible).toBe(true);
      expect(element.textContent).toBe('');
    });

    it('waits longer than the first load before saying anything', () => {
      const { element, loading } = makeIndicator();
      completeFirstLoad(loading);

      loading.beginLoading();
      vi.advanceTimersByTime(INITIAL);

      // The first load's delay is already past, and nothing should be up.
      expect(loading.visible).toBe(false);
      expect(element.textContent).toBe('');

      vi.advanceTimersByTime(BACKGROUND - INITIAL);
      expect(loading.visible).toBe(true);
    });

    it('says the connection is slow only once it has outlasted a normal pan', () => {
      const { element, loading } = makeIndicator();
      completeFirstLoad(loading);

      loading.beginLoading();
      vi.advanceTimersByTime(BACKGROUND);
      expect(element.textContent).toBe('');

      vi.advanceTimersByTime(HINT);
      expect(element.textContent).toBe(BACKGROUND_SLOW_TEXT);
    });

    /** The corner text has to fit a corner, so it is much shorter than the first load's. */
    it('says it in fewer words than the centred indicator does', () => {
      expect(BACKGROUND_SLOW_TEXT.length).toBeLessThan(INITIAL_SLOW_TEXT.length);
    });

    it('never returns to the middle, however many loads go by', () => {
      const { loading } = makeIndicator();
      completeFirstLoad(loading);

      for (let load = 0; load < 5; load += 1) {
        loading.beginLoading();
        vi.advanceTimersByTime(BACKGROUND);
        expect(loading.mode).toBe('background');
        loading.endLoading();
      }
    });
  });

  describe('standing down', () => {
    /**
     * A failed style never reaches `idle`, so without `fail()` the spinner would
     * turn forever beside a banner already naming the dead service.
     */
    it('hands over to the service banner when the style fails', () => {
      const { element, loading } = makeIndicator();

      loading.beginLoading();
      vi.advanceTimersByTime(INITIAL + HINT);
      expect(loading.visible).toBe(true);

      loading.fail();

      expect(loading.visible).toBe(false);
      expect(element.textContent).toBe('');
    });

    /**
     * A map that has never drawn anything has nothing in the corners to tuck an
     * indicator into — it has no frame, no controls, nothing. So a failed first
     * load must not count as "seen once", and the retry gets the centre back.
     */
    it('treats the load after a failed first one as a first load', () => {
      const { element, loading } = makeIndicator();

      loading.beginLoading();
      loading.fail();

      // Whatever the user tries next — a basemap swap, a retry — is still the
      // first thing this map will ever have drawn.
      loading.beginLoading();
      vi.advanceTimersByTime(INITIAL);

      expect(loading.mode).toBe('initial');
      expect(element.classList.contains('map-loader-corner')).toBe(false);
      expect(element.textContent).toBe(INITIAL_TEXT);
    });

    it('drops its pending timers when a load stands down', () => {
      const { element, loading } = makeIndicator();

      loading.beginLoading();
      loading.fail();
      vi.advanceTimersByTime(INITIAL + HINT);

      expect(element.classList.contains('hidden')).toBe(true);
      expect(element.textContent).toBe('');
    });

    it('leaves nothing running after destroy', () => {
      const { element, loading } = makeIndicator();

      loading.beginLoading();
      loading.destroy();
      vi.advanceTimersByTime(INITIAL + HINT);

      expect(element.classList.contains('hidden')).toBe(true);
      expect(element.textContent).toBe('');
      expect(vi.getTimerCount()).toBe(0);
    });
  });

  describe('repeats during one load', () => {
    /**
     * MapLibre fires `dataloading` for every tile it wants while a slow load is
     * still running. Re-arming the reveal on each would push it back forever, and
     * the indicator would never appear at all — the exact failure this exists to
     * fix.
     */
    it('does not re-arm the reveal while a slow load is already counted', () => {
      const { element, loading } = makeIndicator();

      loading.beginLoading();
      vi.advanceTimersByTime(INITIAL / 2);
      loading.beginLoading();
      vi.advanceTimersByTime(INITIAL / 2);

      expect(element.classList.contains('hidden')).toBe(false);
      expect(element.textContent).toBe(INITIAL_TEXT);
    });

    it('does not reset the hint clock on a repeat either', () => {
      const { element, loading } = makeIndicator();

      loading.beginLoading();
      vi.advanceTimersByTime(INITIAL);
      for (let tile = 0; tile < 50; tile += 1) {
        loading.beginLoading();
        vi.advanceTimersByTime(10);
      }

      // Still the plain message: a load that keeps trickling tiles has to be able
      // to get past "Loading map…" rather than being held at it forever.
      expect(element.textContent).toBe(INITIAL_TEXT);
      vi.advanceTimersByTime(HINT);
      expect(element.textContent).toBe(INITIAL_SLOW_TEXT);
    });

    /** A first load and a pan must not be able to change each other's placement. */
    it('cannot be moved out of the centre by a repeat arriving mid-load', () => {
      const { element, loading } = makeIndicator();

      loading.beginLoading();
      vi.advanceTimersByTime(INITIAL / 2);
      loading.beginLoading();
      vi.advanceTimersByTime(INITIAL / 2);

      expect(element.classList.contains('map-loader-corner')).toBe(false);
    });
  });

  describe('ordinary use', () => {
    /** The property both delays exist for. */
    it('never appears for the many short pans of ordinary use', () => {
      const { element, loading } = makeIndicator();
      completeFirstLoad(loading);

      for (let pan = 0; pan < 20; pan += 1) {
        loading.beginLoading();
        vi.advanceTimersByTime(50);
        loading.endLoading();
      }

      expect(loading.visible).toBe(false);
      expect(element.textContent).toBe('');
    });

    it('stays hidden when nothing is loading', () => {
      const { element, loading } = makeIndicator();

      expect(loading.visible).toBe(false);

      loading.beginLoading();
      loading.endLoading();
      loading.beginLoading();
      loading.fail();
      loading.destroy();

      expect(loading.visible).toBe(false);
      expect(loading.mode).toBeNull();
      expect(element.classList.contains('hidden')).toBe(true);
      expect(element.classList.contains('map-loader-corner')).toBe(false);
      expect(element.textContent).toBe('');
    });
  });

  describe('defaults', () => {
    it('answers a first load quickly but keeps pans quiet for longer', () => {
      expect(INITIAL_REVEAL_AFTER_MS).toBeGreaterThanOrEqual(250);
      expect(INITIAL_REVEAL_AFTER_MS).toBeLessThan(1_000);
      expect(BACKGROUND_REVEAL_AFTER_MS).toBeGreaterThan(INITIAL_REVEAL_AFTER_MS);
    });
  });
});