/**
 * The move between the flat map and the 3D relief map (see issue #6).
 *
 * Two things have to happen together: the camera tilts, and the ground under it
 * stops being a plane. Doing them as two separate steps is what read as a jolt —
 * the relief snapped to full height in a single frame and only *then* did the
 * tilt start, so the first thing the eye caught was the snap. Driving both from
 * one progress value means the relief grows out of the plane the map already
 * had while the camera tilts under it.
 *
 * The numbers here are the whole of the animation; wiring it to the map lives
 * in `main.ts`.
 */

/** Ridges read as ridges at route scale only when lifted slightly off true scale. */
export const TERRAIN_EXAGGERATION = 1.15;

/** The tilt the map settles at with the relief on. */
export const TERRAIN_PITCH = 55;

/** The tilt of the flat map the toggle returns to. */
export const FLAT_PITCH = 0;

/**
 * Long enough to read as a move rather than a cut, short enough that a second
 * click lands before the relief has finished moving.
 */
export const TERRAIN_TRANSITION_MS = 700;

/**
 * How long a warm-up may hold the toggle before the move starts anyway.
 *
 * Waiting for the DEM tiles is worth it — relief that grows in as the data
 * arrives reads far better than a cut — but a slow or failing terrain service
 * must not be able to wedge the button.
 */
export const TERRAIN_WARM_TIMEOUT_MS = 1500;

/**
 * How far the camera pulls back, in zoom levels, at the full tilt.
 *
 * Tilting a perspective camera toward the horizon is a trade: the near ground
 * expands to fill the bottom of the frame while the far ground compresses into
 * the distance. Holding the zoom still across that trade is what makes the move
 * read as diving *into* the terrain rather than looking across it. On a summit
 * it is worse than a close crop — the massif simply fills the screen, and at the
 * tighter fits (a bbox result capped at `maxZoom`) the camera can end up level
 * with or below the peak it was sent to.
 *
 * 1.5 levels is the compromise: enough that a 4 km summit stays framed with
 * room around it, little enough that the ground under the marker still reads as
 * the same place the flat map was showing.
 */
export const TERRAIN_ZOOM_OUT = 1.5;

/** The camera's pitch and the relief beneath it — the two halves of one frame. */
export type TerrainView = {
  pitch: number;
  exaggeration: number;
};

/**
 * How many zoom levels `pitch` costs the camera. Zero when flat, the whole
 * pull-back at the full relief tilt, proportional in between.
 */
function pullback(pitch: number): number {
  return TERRAIN_ZOOM_OUT * (Math.max(pitch, FLAT_PITCH) / TERRAIN_PITCH);
}

/**
 * The zoom that shows a flat map's worth of ground at `pitch`.
 *
 * Used by every programmatic camera move, so that the one place the map can be
 * sent somewhere new is the place that knows the camera is tilted. MapLibre
 * will not do this for us: `fitBounds` and `cameraForBounds` both fit as though
 * the camera were looking straight down, and neither accepts a pitch into the
 * maths, so a fit made in 3D lands its target off the top of the frame.
 *
 * Linear in the tilt, so a move part-way through a transition is compensated
 * part-way too.
 *
 * Always pass the same anchor — `untiltedZoom` of wherever the camera last
 * settled — and never the live zoom. Measuring from the live zoom compounds:
 * each move costs a fresh pull-back, and because flattening the tilt
 * compensates nothing, the ground never comes back. Repeatedly switching 3D on
 * and off walks the whole map out to the horizon.
 */
export function tiltZoom(zoom: number, pitch: number): number {
  return Math.max(zoom - pullback(pitch), 0);
}

/**
 * The inverse of `tiltZoom`: the zoom a tilted camera would have at flat pitch.
 *
 * Read off the camera once it settles, this is the anchor every later tilt is
 * measured from, which is what makes the pull-back a fixed point rather than a
 * ratchet — and it keeps a pinch made in 3D, since that changes the scale the
 * flat view is measured in, without any of it having to be tracked by hand.
 */
export function untiltedZoom(zoom: number, pitch: number): number {
  return zoom + pullback(pitch);
}

/** The flat map. An exaggeration of zero is exactly as flat as no terrain at all. */
export const FLAT_VIEW: TerrainView = { pitch: FLAT_PITCH, exaggeration: 0 };

/** The 3D map. */
export const RELIEF_VIEW: TerrainView = { pitch: TERRAIN_PITCH, exaggeration: TERRAIN_EXAGGERATION };

/**
 * MapLibre's own `easeCubicInOut`, reproduced so the relief ramp traces the
 * same curve as the camera's `easeTo`. A different curve would leave the relief
 * leading or lagging the tilt, which reads as a jolt of its own.
 */
export function easeInOutCubic(progress: number): number {
  if (progress <= 0) return 0;
  if (progress >= 1) return 1;
  const squared = progress * progress;
  const cubed = squared * progress;
  return 4 * (progress < 0.5 ? cubed : 3 * (progress - squared) + cubed - 0.75);
}

/**
 * How far along a `duration` transition `elapsed` milliseconds is, eased and
 * clamped to 0..1. A frame that arrives late reads as "finished" rather than
 * overshooting into the next state.
 */
export function transitionProgress(elapsed: number, duration = TERRAIN_TRANSITION_MS): number {
  if (duration <= 0) return 1;
  return easeInOutCubic(elapsed / duration);
}

/** Both halves of the move at `progress` between two views. */
export function terrainAt(from: TerrainView, to: TerrainView, progress: number): TerrainView {
  return {
    pitch: from.pitch + (to.pitch - from.pitch) * progress,
    exaggeration: from.exaggeration + (to.exaggeration - from.exaggeration) * progress,
  };
}

/**
 * Whether a warm-up should keep waiting for the terrain's DEM tiles.
 *
 * Building the terrain costs a few hundred milliseconds of main thread — a pool
 * of render-to-texture framebuffers and a full DEM tile reload — and MapLibre
 * only issues that cost when the terrain is enabled. Doing it on the click is
 * what made the toggle cut rather than move: the transition ran to completion
 * inside the stall, so the first frame anyone saw was already the end state.
 * Enabling it ahead of the click, at an exaggeration of zero so it draws
 * nothing, moves that cost off the click instead.
 *
 * The DEM tiles themselves keep arriving afterwards. Waiting for them is worth
 * it, but only up to a point — past `timeout` the move starts with whatever
 * relief has landed, because a terrain service that never answers must not be
 * able to wedge the button.
 */
export function shouldKeepWaiting(sourceLoaded: boolean, elapsed: number, timeout = TERRAIN_WARM_TIMEOUT_MS): boolean {
  return !sourceLoaded && elapsed < timeout;
}