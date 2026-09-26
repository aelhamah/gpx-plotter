/**
 * How much of the map the sidebar covers, per edge.
 *
 * The sidebar is a translucent panel floating over a full-bleed map, so
 * `fitBounds` has to leave room for it or the fitted content lands underneath.
 * Which edge it covers depends on the layout: a 330px column on the left on
 * wide viewports, a full-width sheet along the bottom under 800px. Measuring
 * the real rect keeps both layouts correct instead of hard-coding one of them.
 *
 * Pure geometry (no DOM), so it is unit-testable.
 */

export interface EdgeInsets {
  top: number;
  bottom: number;
  left: number;
  right: number;
}

export interface RectLike {
  left: number;
  top: number;
  right: number;
  bottom: number;
  width: number;
  height: number;
}

/** Slack for sub-pixel layout sizes, so a flush edge still counts as covered. */
const EPSILON = 1;

const NO_INSETS: EdgeInsets = { top: 0, bottom: 0, left: 0, right: 0 };

/**
 * Inset, per container edge, that the sidebar occupies — 0 on edges it does not
 * cover. Coordinates are viewport/client based, so both rects must come from the
 * same frame (e.g. two `getBoundingClientRect()` calls).
 */
export function sidebarInsets(sidebar: RectLike | null, container: RectLike | null): EdgeInsets {
  if (!sidebar || !container || container.width <= 0 || container.height <= 0) return { ...NO_INSETS };

  // Clip the sidebar to the container so a scrolled or partially offscreen
  // sidebar only occludes the part that is actually over the map.
  const left = Math.max(sidebar.left, container.left);
  const top = Math.max(sidebar.top, container.top);
  const right = Math.min(sidebar.right, container.right);
  const bottom = Math.min(sidebar.bottom, container.bottom);
  if (right - left <= EPSILON || bottom - top <= EPSILON) return { ...NO_INSETS };

  const flushLeft = left <= container.left + EPSILON;
  const flushRight = right >= container.right - EPSILON;
  const flushTop = top <= container.top + EPSILON;
  const flushBottom = bottom >= container.bottom - EPSILON;

  // A full-width sheet (narrow viewports) occludes vertically; anything else —
  // the desktop column — occludes horizontally. Padding the wrong axis would
  // push the route off-centre, so pick the axis from the measured overlap.
  if (right - left >= container.width - EPSILON) {
    return {
      ...NO_INSETS,
      top: flushTop ? bottom - container.top : 0,
      bottom: flushBottom ? container.bottom - top : 0,
    };
  }
  return {
    ...NO_INSETS,
    left: flushLeft ? right - container.left : 0,
    right: flushRight ? container.right - left : 0,
  };
}

/** `sidebarInsets` plus a uniform breathing margin, in the shape `fitBounds` wants. */
export function fitPadding(sidebar: RectLike | null, container: RectLike | null, margin = 0): EdgeInsets {
  const insets = sidebarInsets(sidebar, container);
  return {
    top: insets.top + margin,
    bottom: insets.bottom + margin,
    left: insets.left + margin,
    right: insets.right + margin,
  };
}
