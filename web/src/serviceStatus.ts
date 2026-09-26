/**
 * A single banner for when a backing service stops answering.
 *
 * Everything remote in this app is optional in a way that hides its own
 * failure: the basemap is one style URL, elevation is a DEM tile per point,
 * search is one geocoding call. When any of them dies the app keeps working —
 * it just shows a blank map, a row of em dashes and a profile that never draws,
 * which looks exactly like a bug in the app and gives the user nothing to act
 * on. MapLibre funnels style, tile and terrain-source failures through one
 * `error` event that still carries the failing URL, so classifying that message
 * is enough to name the service; DEM and geocoding fetch their own URLs and
 * report through `reportServiceFailure` instead.
 *
 * The banner holds no state beyond which services are currently unhappy: it
 * clears a service the moment it answers again, so a rate limit that lifts
 * leaves nothing behind.
 */

export type ServiceKind = 'style' | 'basemap' | 'elevation' | 'search';

export interface ServiceIssue {
  kind: ServiceKind;
  /** The raw failure text, kept for the console but never shown verbatim. */
  detail: string;
  rateLimited: boolean;
  /** How many failures have been folded into this issue. */
  count: number;
}

/**
 * Which service a failure belongs to, from the message MapLibre (or our own
 * fetch code) produced. Returns null for anything that isn't a request to a
 * service we depend on — MapLibre raises errors for plenty of local trouble
 * that the user cannot act on and should not be interrupted for.
 *
 * Order matters: the terrain and geocoding paths also match the generic host.
 */
export function classifyServiceFailure(message: string): ServiceKind | null {
  const text = message.toLowerCase();
  if (text.includes('terrain-rgb') || text.includes('dem tile')) return 'elevation';
  if (text.includes('geocoding')) return 'search';
  if (text.includes('style.json')) return 'style';
  if (text.includes('api.maptiler.com')) return 'basemap';
  return null;
}

/** MapTiler's free plan answers an over-quota request with 429, not a 5xx. */
export function looksRateLimited(message: string): boolean {
  return /\b429\b|too many requests|rate limit/i.test(message);
}

const SERVICE_TEXT: Record<ServiceKind, string> = {
  style: "Basemap won't load — routes, terrain and search all depend on it.",
  basemap: 'Some basemap tiles failed to load.',
  elevation: "Terrain won't load — elevation stats and the profile can't be filled.",
  search: "Search won't load.",
};

/** How loudly to complain about a given set of issues. */
export type ServiceLevel = 'error' | 'warning';

export interface ServiceSummary {
  level: ServiceLevel;
  text: string;
}

/**
 * One sentence covering everything that is currently down, loudest first. A dead
 * style subsumes the rest — no map means no terrain and no search either — so
 * the banner leads with it and only lists what is still worth naming.
 */
export function summarizeServices(issues: readonly ServiceIssue[]): ServiceSummary | null {
  const kinds = new Set(issues.map((issue) => issue.kind));
  if (!kinds.size) return null;
  const order: ServiceKind[] = ['style', 'elevation', 'search', 'basemap'];
  const parts = order.filter((kind) => kinds.has(kind)).map((kind) => SERVICE_TEXT[kind]);
  // A rate limit is a different situation from a broken endpoint: nothing is
  // wrong, the plan just ran out of requests for now, and it clears itself.
  if (issues.some((issue) => issue.rateLimited)) {
    parts.push("MapTiler's free plan caps request volume, so this usually clears on its own.");
  }
  return { level: kinds.has('style') || kinds.has('elevation') ? 'error' : 'warning', text: parts.join(' ') };
}

type FailureListener = (issue: Omit<ServiceIssue, 'count'>) => void;

const listeners = new Set<FailureListener>();

/**
 * Report a failure from code that fetches outside MapLibre's error event.
 * Keeping the entry point here means `dem.ts` and `geocode.ts` can flag a dead
 * service without importing anything that knows about the DOM.
 */
export function reportServiceFailure(kind: ServiceKind, detail = ''): void {
  const issue = { kind, detail, rateLimited: looksRateLimited(detail) };
  for (const listener of listeners) listener(issue);
}

/** Subscribe to failures from those services. Returns an unsubscribe function. */
export function onServiceFailure(listener: FailureListener): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

/** Tracks which services are unhappy and renders the banner for them. */
export class ServiceStatus {
  private readonly issues = new Map<ServiceKind, ServiceIssue>();

  constructor(private readonly element: HTMLElement) {}

  /** Record a failure. Repeat reports of the same service are folded together. */
  report(kind: ServiceKind, detail = '', rateLimited = looksRateLimited(detail)): void {
    const existing = this.issues.get(kind);
    this.issues.set(kind, {
      kind,
      detail,
      rateLimited: rateLimited || (existing?.rateLimited ?? false),
      count: (existing?.count ?? 0) + 1,
    });
    this.render();
  }

  /** A service answered again, so stop blaming it. */
  resolve(kind: ServiceKind): void {
    if (this.issues.delete(kind)) this.render();
  }

  clear(): void {
    if (this.issues.size) {
      this.issues.clear();
      this.render();
    }
  }

  get active(): readonly ServiceIssue[] {
    return [...this.issues.values()];
  }

  private render(): void {
    const summary = summarizeServices([...this.issues.values()]);
    if (!summary) {
      // Reset the level class too, or a recovered service leaves its last
      // severity on an element that is only hidden by luck of the cascade.
      this.element.textContent = '';
      this.element.className = 'service-banner hidden';
      return;
    }
    this.element.textContent = summary.text;
    this.element.className = `service-banner service-banner-${summary.level}`;
  }
}
