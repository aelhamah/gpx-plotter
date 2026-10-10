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

/** The camera's pitch and the relief beneath it — the two halves of one frame. */
export type TerrainView = {
  pitch: number;
  exaggeration: number;
};

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