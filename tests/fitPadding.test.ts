import { describe, expect, it } from 'vitest';
import { fitPadding, sidebarInsets, type RectLike } from '../src/fitPadding';

function rect(left: number, top: number, width: number, height: number): RectLike {
  return { left, top, width, height, right: left + width, bottom: top + height };
}

const container = rect(0, 0, 1440, 900);
/** Desktop: 330px column down the left edge. */
const leftColumn = rect(0, 0, 330, 900);
/** Narrow viewport: full-width sheet pinned to the bottom, up to 46vh. */
const bottomSheet = rect(0, 508, 800, 392);

describe('sidebarInsets', () => {
  it('reports the left column on wide viewports', () => {
    expect(sidebarInsets(leftColumn, container)).toEqual({ top: 0, bottom: 0, left: 330, right: 0 });
  });

  it('reports the bottom sheet on narrow viewports', () => {
    // Regression: the sheet occludes the bottom edge, so padding the left (as a
    // hard-coded sidebar width would) would leave the route under the sheet.
    expect(sidebarInsets(bottomSheet, rect(0, 0, 800, 900))).toEqual({ top: 0, bottom: 392, left: 0, right: 0 });
  });

  it('reports a full-width top bar against the top edge', () => {
    expect(sidebarInsets(rect(0, 0, 1440, 60), container)).toEqual({ top: 60, bottom: 0, left: 0, right: 0 });
  });

  it('reports a right-hand column', () => {
    expect(sidebarInsets(rect(1110, 0, 330, 900), container)).toEqual({ top: 0, bottom: 0, left: 0, right: 330 });
  });

  it('offsets by the container position, not the viewport origin', () => {
    // A map that does not start at the viewport origin: a 300px column flush to
    // the map's own left edge, 200px in from the viewport.
    const inner = rect(200, 100, 400, 700);
    expect(sidebarInsets(rect(200, 100, 300, 700), inner)).toEqual({ top: 0, bottom: 0, left: 300, right: 0 });
  });

  it('reports nothing when the sidebar is missing or the map has no size', () => {
    const none = { top: 0, bottom: 0, left: 0, right: 0 };
    expect(sidebarInsets(null, container)).toEqual(none);
    expect(sidebarInsets(leftColumn, null)).toEqual(none);
    expect(sidebarInsets(leftColumn, rect(0, 0, 0, 0))).toEqual(none);
  });

  it('reports nothing when the sidebar does not overlap the map', () => {
    const none = { top: 0, bottom: 0, left: 0, right: 0 };
    expect(sidebarInsets(rect(0, 0, 100, 100), rect(500, 0, 400, 400))).toEqual(none);
  });

  it('clips a sidebar that hangs off the edge of the map', () => {
    // A 330px column dragged half off a 200px-wide map only covers 200px.
    expect(sidebarInsets(rect(-165, 0, 330, 400), rect(0, 0, 200, 400))).toEqual({ top: 0, bottom: 0, left: 165, right: 0 });
  });

  it('tolerates sub-pixel flush edges', () => {
    expect(sidebarInsets(rect(0.4, 0, 329.6, 900), container).left).toBe(330);
  });
});

describe('fitPadding', () => {
  it('adds a uniform margin to the covered edges only', () => {
    expect(fitPadding(leftColumn, container, 80)).toEqual({ top: 80, bottom: 80, left: 410, right: 80 });
  });

  it('adds the margin to the bottom for the narrow layout', () => {
    expect(fitPadding(bottomSheet, rect(0, 0, 800, 900), 80)).toEqual({ top: 80, bottom: 472, left: 80, right: 80 });
  });

  it('falls back to an even margin when the sidebar cannot be measured', () => {
    expect(fitPadding(null, container, 80)).toEqual({ top: 80, bottom: 80, left: 80, right: 80 });
  });

  it('defaults to no margin', () => {
    expect(fitPadding(leftColumn, container)).toEqual({ top: 0, bottom: 0, left: 330, right: 0 });
  });
});
