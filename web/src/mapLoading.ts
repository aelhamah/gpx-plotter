/**
 * A loading indicator for the basemap (issue #54).
 *
 * On a slow connection the map is a blank grey rectangle for several seconds and
 * nothing in the app says otherwise. The banner in `serviceStatus.ts` covers the
 * opposite case — something is *broken* — so this covers the gap between "hasn't
 * arrived yet" and "arrived", which on a first load over a hotel connection can be
 * a long gap. Without it the page reads as a blank page, and the first thing a
 * user does is reload, which starts the wait again from zero.
 *
 * ## Why nothing is shown straight away
 *
 * MapLibre raises `dataloading` for every pan, zoom and style swap, and nearly all
 * of them settle within a few tens of milliseconds. An indicator that appears on
 * each one reads as a flicker, and one that has been flickering on every pan is
 * one the user has stopped looking at by the time they need it. So this waits out
 * `revealAfterMs` of *continuous* loading before it appears: on a working
 * connection that threshold is never reached, and on a slow one it is reached at
 * once.
 *
 * ## Why the message changes later
 *
 * A spinner on its own is indistinguishable from a hang, which is the other way
 * the same wait reads as a broken page. After `hintAfterMs` the text says the wait
 * itself is the slow part, so the user knows to stay rather than reload.
 *
 * ## Why a failed style stands it down
 *
 * A style request that fails never reaches `idle`, so a load that is never going
 * to finish would spin forever beside a banner already explaining itself. `fail()`
 * hands the message over: the banner names the service that died, and a spinner
 * still turning next to it would be claiming work is in progress that is not.
 */

/**
 * How long the map must be continuously loading before the indicator appears.
 *
 * Short enough that a slow connection gets feedback before it looks broken, long
 * enough that ordinary panning never flashes one.
 */
export const REVEAL_AFTER_MS = 400;

/** How long before the message stops pretending this is normal. */
export const HINT_AFTER_MS = 8_000;

/** Shown while loading. */
export const LOADING_TEXT = 'Loading map…';

/**
 * Shown once the wait is long enough to read as a problem rather than a pause.
 * Deliberately says the connection is slow instead of naming a service: nothing
 * has failed, so there is nothing to blame, and a message that named one would be
 * a guess.
 */
export const SLOW_TEXT = 'Still loading — this is normal on a slow connection.';

/**
 * Reveals a spinner over the map while the basemap is loading.
 *
 * Driven by MapLibre's `dataloading` and `idle` events, and by an explicit
 * `beginLoading()` for the first load — see `main.ts`, where the constructor
 * starts the style request before a listener can be attached to it.
 *
 * The element holds only text; the spinner itself is drawn by `.map-loader`'s
 * `::before`, the same way `.service-banner` draws its icon. That keeps the
 * element's markup in `index.html` and this module free of any assumption about
 * what is inside it.
 */
export class MapLoading {
  /** Whether the map currently has work in flight. Guards the timers. */
  private loading = false;

  private revealTimer: ReturnType<typeof setTimeout> | undefined;

  private hintTimer: ReturnType<typeof setTimeout> | undefined;

  constructor(
    private readonly element: HTMLElement,
    private readonly revealAfterMs: number = REVEAL_AFTER_MS,
    private readonly hintAfterMs: number = HINT_AFTER_MS,
  ) {}

  /** Whether the indicator is on screen. */
  get visible(): boolean {
    return !this.element.classList.contains('hidden');
  }

  /** The map has work in flight. Idempotent: a repeat call keeps the first timer. */
  beginLoading(): void {
    // MapLibre fires this for every tile it wants while a slow load is still in
    // progress, so this runs repeatedly during exactly the wait that matters.
    // Re-arming on each one would push the reveal back on every new tile and the
    // indicator would never appear at all, which is the bug this class exists to
    // fix. The first call owns the timers until something ends the load.
    if (this.loading) return;
    this.loading = true;
    this.revealTimer = setTimeout(() => {
      this.revealTimer = undefined;
      this.render(LOADING_TEXT);
      this.hintTimer = setTimeout(() => {
        this.hintTimer = undefined;
        this.render(SLOW_TEXT);
      }, this.hintAfterMs);
    }, this.revealAfterMs);
  }

  /** Everything requested has arrived and been drawn. */
  endLoading(): void {
    this.stop();
  }

  /**
   * The basemap will never arrive, and something else is already saying so.
   *
   * Distinct from `endLoading()` only in intent, and worth keeping distinct: a
   * stopped load and a dead one leave the screen in the same state but mean
   * different things to whoever reads this later.
   */
  fail(): void {
    this.stop();
  }

  /** Stop for good and drop any pending timer. */
  destroy(): void {
    this.stop();
  }

  private stop(): void {
    this.loading = false;
    clearTimeout(this.revealTimer);
    clearTimeout(this.hintTimer);
    this.revealTimer = undefined;
    this.hintTimer = undefined;
    this.element.textContent = '';
    this.element.classList.add('hidden');
  }

  private render(text: string): void {
    this.element.textContent = text;
    this.element.classList.remove('hidden');
  }
}