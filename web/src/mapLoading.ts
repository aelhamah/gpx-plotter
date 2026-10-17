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
 * ## Two places, because they are two different situations
 *
 * The first load has nothing else on screen, so it gets the middle of the map and
 * a sentence. Every load after that is the map re-fetching underneath someone who
 * is already using it — a pan, a zoom, a basemap swap — and that gets a bare dot
 * in a corner. Centred, it lands on the thing the user is looking at and reports
 * motion they just caused as though something had gone wrong, which is worse than
 * saying nothing at all: an indicator that appears on every zoom teaches people to
 * ignore it, so the one load that matters gets ignored too.
 *
 * ## Why the delays differ, too
 *
 * The first load is a blind wait and deserves a fast answer. A pan is feedback
 * about something the user just did and mostly resolves in a few hundred
 * milliseconds, so it waits out considerably longer before it says anything.
 *
 * ## Why nothing shows for a while in either case
 *
 * MapLibre raises `dataloading` for every pan, zoom and style swap, and nearly all
 * of them settle within a few tens of milliseconds. An indicator that appeared on
 * each would be a flicker, and one that has been flickering on every pan is one
 * the user has stopped looking at by the time they need it.
 *
 * ## Why the message changes later
 *
 * A spinner on its own is indistinguishable from a hang, which is the other way
 * the same wait reads as a broken page. After `hintAfterMs` the text says the wait
 * itself is the slow part, so the user knows to stay rather than reload. In the
 * corner that starts from a bare dot, so it appears only once the wait is long
 * enough to have earned the words.
 *
 * ## Why a failed style stands it down
 *
 * A style request that fails never reaches `idle`, so a load that is never going
 * to finish would spin forever beside a banner already explaining itself. `fail()`
 * hands the message over: the banner names the service that died, and a spinner
 * still turning next to it would be claiming work is in progress that is not.
 * A failed load also does *not* count as "the map has been seen once" — nothing
 * rendered, so the next attempt is still a first load and still belongs in the
 * middle.
 */

/**
 * Where the indicator is showing, which is also how loud it is being.
 *
 * `initial` is the load before the map has ever drawn anything. `background` is
 * every load after that.
 */
export type MapLoadingMode = 'initial' | 'background';

/**
 * How long the first load must run before the centred indicator appears.
 *
 * Short enough that a slow connection gets feedback before it looks broken, long
 * enough that a quick one never flashes.
 */
export const INITIAL_REVEAL_AFTER_MS = 400;

/**
 * How long a pan or zoom must run before the corner dot appears.
 *
 * Longer than the first load's, because this one is reporting something the user
 * just did. Most of them finish inside this and say nothing at all.
 */
export const BACKGROUND_REVEAL_AFTER_MS = 900;

/** How long before the message stops pretending this is normal. */
export const HINT_AFTER_MS = 8_000;

/** The first load: the map is empty, so it is worth saying what is happening. */
export const INITIAL_TEXT = 'Loading map…';

/**
 * The first load, once it has gone on long enough to read as a problem. Says the
 * connection is the slow part and names no service, because nothing has failed and
 * a message naming one would be a guess.
 */
export const INITIAL_SLOW_TEXT = 'Still loading — this is normal on a slow connection.';

/** A corner indicator that has outlasted a normal pan. Kept short — it is in a corner. */
export const BACKGROUND_SLOW_TEXT = 'Slow connection';

export interface MapLoadingOptions {
  /** Defaults to {@link INITIAL_REVEAL_AFTER_MS}. */
  initialRevealAfterMs?: number;
  /** Defaults to {@link BACKGROUND_REVEAL_AFTER_MS}. */
  backgroundRevealAfterMs?: number;
  /** Defaults to {@link HINT_AFTER_MS}. */
  hintAfterMs?: number;
}

/** The class that moves the indicator out of the middle and into the corner. */
const CORNER_CLASS = 'map-loader-corner';

/**
 * Reveals a spinner over the map while the basemap is loading: centred and worded
 * for the first load, a bare dot in a corner for every load after it.
 *
 * Driven by MapLibre's `dataloading` and `idle` events, and by an explicit
 * `beginLoading()` for the first load — see `main.ts`, where the constructor starts
 * the style request before a listener can be attached to it.
 *
 * The element holds only text; the spinner itself is drawn by `.map-loader`'s
 * `::before`, the same way `.service-banner` draws its icon. That keeps the
 * element's markup in `index.html` and this module free of any assumption about
 * what is inside it.
 */
export class MapLoading {
  /** Whether the map currently has work in flight. Guards the timers. */
  private loading = false;

  /** Whether the map has ever finished a load. Decides which mode comes next. */
  private loadedOnce = false;

  /** Which mode is on screen, or null while hidden. */
  private revealedMode: MapLoadingMode | null = null;

  private revealTimer: ReturnType<typeof setTimeout> | undefined;

  private hintTimer: ReturnType<typeof setTimeout> | undefined;

  private readonly initialRevealAfterMs: number;

  private readonly backgroundRevealAfterMs: number;

  private readonly hintAfterMs: number;

  constructor(private readonly element: HTMLElement, options: MapLoadingOptions = {}) {
    this.initialRevealAfterMs = options.initialRevealAfterMs ?? INITIAL_REVEAL_AFTER_MS;
    this.backgroundRevealAfterMs = options.backgroundRevealAfterMs ?? BACKGROUND_REVEAL_AFTER_MS;
    this.hintAfterMs = options.hintAfterMs ?? HINT_AFTER_MS;
  }

  /** Whether the indicator is on screen. */
  get visible(): boolean {
    return this.revealedMode !== null;
  }

  /** Which placement is showing, or null while hidden. */
  get mode(): MapLoadingMode | null {
    return this.revealedMode;
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

    // Captured now rather than read when the timer fires: the mode is a property
    // of the load that started, and a basemap swap cannot make a first load into
    // a background one while it is still going.
    const mode: MapLoadingMode = this.loadedOnce ? 'background' : 'initial';
    const delay = mode === 'initial' ? this.initialRevealAfterMs : this.backgroundRevealAfterMs;

    this.revealTimer = setTimeout(() => {
      this.revealTimer = undefined;
      this.reveal(mode, false);
      this.hintTimer = setTimeout(() => {
        this.hintTimer = undefined;
        this.reveal(mode, true);
      }, this.hintAfterMs);
    }, delay);
  }

  /** Everything requested has arrived and been drawn. */
  endLoading(): void {
    // Only a load that actually drew counts. This is the line between the centred
    // first-load indicator and the corner dot, so it is set here and deliberately
    // *not* in `fail()`.
    this.loadedOnce = true;
    this.stop();
  }

  /**
   * The basemap will never arrive, and something else is already saying so.
   *
   * Distinct from `endLoading()` because of what it leaves behind: this does not
   * mark the map as seen, so a later attempt is still treated as a first load and
   * still gets the centred indicator. A map that has never drawn anything has
   * nothing in the corners to tuck an indicator into.
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
    this.revealedMode = null;
    this.element.textContent = '';
    this.element.classList.add('hidden');
    this.element.classList.remove(CORNER_CLASS);
  }

  private reveal(mode: MapLoadingMode, hinted: boolean): void {
    this.revealedMode = mode;
    this.element.textContent = this.textFor(mode, hinted);
    this.element.classList.toggle(CORNER_CLASS, mode === 'background');
    this.element.classList.remove('hidden');
  }

  private textFor(mode: MapLoadingMode, hinted: boolean): string {
    if (mode === 'initial') return hinted ? INITIAL_SLOW_TEXT : INITIAL_TEXT;
    // A corner dot is only worth the words once the wait is long enough to have
    // earned them. Before that it is silent, which is the whole point of it.
    return hinted ? BACKGROUND_SLOW_TEXT : '';
  }
}