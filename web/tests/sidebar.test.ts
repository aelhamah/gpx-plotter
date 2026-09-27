// @vitest-environment jsdom
/**
 * Sidebar reachability guards.
 *
 * The sidebar is mostly `pointer-events: none` so the map can be dragged under it,
 * with controls opting back in — either as a direct child of `.sidebar`, or via an
 * explicit rule. A control placed inside one of the click-through blocks
 * (`.brand`, `#map-status`, `.help`, `.stats`) inherits `none` and its clicks land
 * on the map instead: no error, no console warning, just a button that does
 * nothing. That already bit the units toggle once, which is why `style.test.ts`
 * exists for the CSS side of it.
 *
 * These assertions cover the HTML side, plus the one thing unit tests cannot reach
 * at all: that the toggle's initial markup agrees with the snapping default, so it
 * does not render one state and then switch to the other as the app boots.
 */
import html from '../index.html?raw';
import { describe, expect, it } from 'vitest';
import { SNAP_ENABLED_BY_DEFAULT } from '../src/snap';

const doc = new DOMParser().parseFromString(html, 'text/html');

/** Blocks that are `pointer-events: none`; a control inside one is unreachable. */
const CLICK_THROUGH = ['.brand', '#map-status', '.help', '.stats'];

function ancestors(el: Element): Element[] {
  const out: Element[] = [];
  for (let node = el.parentElement; node; node = node.parentElement) out.push(node);
  return out;
}

describe('the snap toggle', () => {
  const toggle = doc.getElementById('snap-toggle');

  it('is a real button with an accessible name', () => {
    expect(toggle).not.toBeNull();
    expect(toggle!.tagName).toBe('BUTTON');
    // Without type, a button inside a form would submit it.
    expect(toggle!.getAttribute('type')).toBe('button');
    expect(toggle!.getAttribute('aria-label')).toBeTruthy();
    expect(toggle!.textContent?.trim()).toBe('Snap to trails');
  });

  it('is not swallowed by a click-through block', () => {
    const inside = ancestors(toggle!).filter((node) =>
      CLICK_THROUGH.some((selector) => node.matches(selector)),
    );
    expect(inside.map((node) => node.id || node.className)).toEqual([]);
  });

  it('renders in the default state so it does not flip on boot', () => {
    // main.ts calls setSnappingEnabled at startup, which re-applies the state. If
    // the markup disagreed with SNAP_ENABLED_BY_DEFAULT the button would show the
    // wrong thing until then.
    expect(toggle!.classList.contains('active')).toBe(SNAP_ENABLED_BY_DEFAULT);
    expect(toggle!.getAttribute('aria-pressed')).toBe(String(SNAP_ENABLED_BY_DEFAULT));
  });

  it('sits inside the sidebar rather than floating over the map', () => {
    expect(toggle!.closest('.sidebar')).not.toBeNull();
  });
});

describe('the snapping copy the app overwrites at runtime', () => {
  it('describes the default state in the static markup', () => {
    // Both strings are rewritten on draw/waypoint mode. The shipped markup should
    // still read correctly for the default, which is snapping on.
    expect(doc.getElementById('draw-status')?.textContent).toContain('snaps to trails');
    expect(doc.getElementById('draw-hint')?.textContent).toContain('snaps to peaks');
  });
});
