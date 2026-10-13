import { describe, expect, it } from 'vitest';
import {
  FLAT_VIEW,
  RELIEF_VIEW,
  TERRAIN_EXAGGERATION,
  TERRAIN_PITCH,
  TERRAIN_TRANSITION_MS,
  TERRAIN_WARM_TIMEOUT_MS,
  TERRAIN_ZOOM_OUT,
  easeInOutCubic,
  shouldKeepWaiting,
  terrainAt,
  tiltZoom,
  transitionProgress,
  untiltedZoom,
} from '../src/terrain';

/** Every frame a transition puts on screen, at roughly 60fps. */
function frames(duration = TERRAIN_TRANSITION_MS, count = 42) {
  return Array.from({ length: count + 1 }, (_, index) => (index * duration) / count);
}

describe('easeInOutCubic', () => {
  it('pins both ends', () => {
    expect(easeInOutCubic(0)).toBe(0);
    expect(easeInOutCubic(1)).toBe(1);
  });
  it('sits at the midpoint halfway', () => {
    expect(easeInOutCubic(0.5)).toBeCloseTo(0.5, 10);
  });
  it('clamps outside 0..1 rather than overshooting', () => {
    expect(easeInOutCubic(-2)).toBe(0);
    expect(easeInOutCubic(4)).toBe(1);
  });
  it('never runs backwards', () => {
    const eased = Array.from({ length: 101 }, (_, index) => easeInOutCubic(index / 100));
    for (let i = 1; i < eased.length; i++) expect(eased[i]).toBeGreaterThanOrEqual(eased[i - 1]);
  });
  it('starts and ends gently, so neither end of the move snaps', () => {
    // The jolt this exists to remove: the first tenth of the time must cover a
    // small slice of the move, not all of it.
    expect(easeInOutCubic(0.1)).toBeLessThan(0.1);
    expect(easeInOutCubic(0.9)).toBeGreaterThan(0.9);
  });
});

describe('transitionProgress', () => {
  it('is 0 at the start and 1 once the duration has passed', () => {
    expect(transitionProgress(0)).toBe(0);
    expect(transitionProgress(TERRAIN_TRANSITION_MS)).toBe(1);
  });
  it('clamps a late frame instead of overshooting', () => {
    expect(transitionProgress(TERRAIN_TRANSITION_MS * 3)).toBe(1);
  });
  it('treats a zero-length transition as instant rather than dividing by zero', () => {
    expect(transitionProgress(0, 0)).toBe(1);
    expect(transitionProgress(500, 0)).toBe(1);
  });
  it('eases rather than moving linearly', () => {
    expect(transitionProgress(TERRAIN_TRANSITION_MS / 2)).toBeCloseTo(0.5, 10);
    expect(transitionProgress(TERRAIN_TRANSITION_MS / 4)).toBeLessThan(0.25);
  });
});

describe('terrainAt', () => {
  it('returns the start and the end exactly', () => {
    expect(terrainAt(FLAT_VIEW, RELIEF_VIEW, 0)).toEqual(FLAT_VIEW);
    expect(terrainAt(FLAT_VIEW, RELIEF_VIEW, 1)).toEqual(RELIEF_VIEW);
  });
  it('is halfway at halfway', () => {
    const halfway = terrainAt(FLAT_VIEW, RELIEF_VIEW, 0.5);
    expect(halfway.pitch).toBeCloseTo(TERRAIN_PITCH / 2, 10);
    expect(halfway.exaggeration).toBeCloseTo(TERRAIN_EXAGGERATION / 2, 10);
  });
  it('runs backwards when the views are swapped', () => {
    expect(terrainAt(RELIEF_VIEW, FLAT_VIEW, 0.5)).toEqual(terrainAt(FLAT_VIEW, RELIEF_VIEW, 0.5));
  });

  describe('turning the relief on', () => {
    it('begins indistinguishable from the flat map, so the first frame cannot jolt', () => {
      const first = terrainAt(FLAT_VIEW, RELIEF_VIEW, transitionProgress(0));
      expect(first.exaggeration).toBe(0);
      expect(first.pitch).toBe(0);
    });
    it('keeps both halves moving together', () => {
      const on = frames().map((elapsed) => terrainAt(FLAT_VIEW, RELIEF_VIEW, transitionProgress(elapsed)));
      for (let i = 1; i < on.length; i++) {
        expect(on[i].pitch).toBeGreaterThanOrEqual(on[i - 1].pitch);
        expect(on[i].exaggeration).toBeGreaterThanOrEqual(on[i - 1].exaggeration);
      }
    });
    it('keeps the ground and the camera in exactly the same step', () => {
      // Relief racing ahead of the tilt is the same jolt, split in two.
      for (const elapsed of frames()) {
        const view = terrainAt(FLAT_VIEW, RELIEF_VIEW, transitionProgress(elapsed));
        expect(view.exaggeration / TERRAIN_EXAGGERATION).toBeCloseTo(view.pitch / TERRAIN_PITCH, 10);
      }
    });
  });

  describe('turning the relief off', () => {
    it('ends flat rather than tearing the terrain down mid-move', () => {
      const last = terrainAt(RELIEF_VIEW, FLAT_VIEW, transitionProgress(TERRAIN_TRANSITION_MS));
      expect(last.exaggeration).toBe(0);
      expect(last.pitch).toBe(0);
    });
    it('shrinks the ground and the tilt together', () => {
      const off = frames().map((elapsed) => terrainAt(RELIEF_VIEW, FLAT_VIEW, transitionProgress(elapsed)));
      for (let i = 1; i < off.length; i++) {
        expect(off[i].pitch).toBeLessThanOrEqual(off[i - 1].pitch);
        expect(off[i].exaggeration).toBeLessThanOrEqual(off[i - 1].exaggeration);
      }
    });
  });

  it('resumes from wherever a half-finished move was interrupted', () => {
    const interrupted = terrainAt(RELIEF_VIEW, FLAT_VIEW, transitionProgress(200));
    const resumed = terrainAt(interrupted, RELIEF_VIEW, transitionProgress(300));
    expect(resumed.pitch).toBeGreaterThan(interrupted.pitch);
    expect(resumed.pitch).toBeLessThan(TERRAIN_PITCH);
    expect(resumed.exaggeration).toBeGreaterThan(interrupted.exaggeration);
    expect(resumed.exaggeration).toBeLessThan(TERRAIN_EXAGGERATION);
  });
});

describe('shouldKeepWaiting', () => {
  it('waits while the DEM tiles are still arriving', () => {
    expect(shouldKeepWaiting(false, 0)).toBe(true);
    expect(shouldKeepWaiting(false, TERRAIN_WARM_TIMEOUT_MS - 1)).toBe(true);
  });
  it('stops as soon as the terrain is ready', () => {
    expect(shouldKeepWaiting(true, 0)).toBe(false);
    expect(shouldKeepWaiting(true, TERRAIN_WARM_TIMEOUT_MS)).toBe(false);
  });
  it('gives up at the timeout, so a dead terrain service cannot wedge the toggle', () => {
    expect(shouldKeepWaiting(false, TERRAIN_WARM_TIMEOUT_MS)).toBe(false);
    expect(shouldKeepWaiting(false, TERRAIN_WARM_TIMEOUT_MS + 5000)).toBe(false);
  });
  it('respects a custom timeout', () => {
    expect(shouldKeepWaiting(false, 500, 1000)).toBe(true);
    expect(shouldKeepWaiting(false, 1000, 1000)).toBe(false);
  });
});

describe('tiltZoom', () => {
  /** `SEARCH_POINT_ZOOM` in `main.ts`: the frame a summit lands in when flat. */
  const SEARCH_POINT_ZOOM = 13;

  it('leaves a flat camera alone', () => {
    expect(tiltZoom(13, FLAT_VIEW.pitch)).toBe(13);
  });
  it('pulls back a whole step at the full tilt', () => {
    // The search frame for a summit, which is where "too zoomed in" came from.
    expect(tiltZoom(SEARCH_POINT_ZOOM, TERRAIN_PITCH)).toBeCloseTo(SEARCH_POINT_ZOOM - TERRAIN_ZOOM_OUT, 10);
  });
  it('is halfway pulled back at half the tilt, so a half-finished move is compensated half-way', () => {
    expect(tiltZoom(13, TERRAIN_PITCH / 2)).toBeCloseTo(13 - TERRAIN_ZOOM_OUT / 2, 10);
  });
  it('only ever zooms out, never in — compensation must not crop the ground away', () => {
    for (const pitch of [0, 10, 27.5, 55, 85]) {
      expect(tiltZoom(12, pitch)).toBeLessThanOrEqual(12);
    }
  });
  it('stops at the world rather than going negative', () => {
    expect(tiltZoom(0.5, TERRAIN_PITCH)).toBe(0);
  });
  it('pulls back further as the tilt goes past the relief pitch', () => {
    expect(tiltZoom(13, 85)).toBeLessThan(tiltZoom(13, TERRAIN_PITCH));
  });

  describe('anchored on the flat zoom', () => {
    // The ratchet: compensating the live zoom charges a fresh pull-back every
    // time 3D is switched on, and flattening compensates nothing, so the ground
    // never comes back. Measuring from one anchor makes it a fixed point.
    it('returns to where it started when the tilt goes back to flat', () => {
      const anchor = 13;
      const tilted = tiltZoom(anchor, TERRAIN_PITCH);
      expect(untiltedZoom(tilted, TERRAIN_PITCH)).toBeCloseTo(anchor, 10);
      expect(tiltZoom(untiltedZoom(tilted, TERRAIN_PITCH), FLAT_VIEW.pitch)).toBeCloseTo(anchor, 10);
    });
    it('holds its zoom across any number of on/off cycles', () => {
      let zoom = 13;
      for (let cycle = 0; cycle < 25; cycle++) {
        zoom = tiltZoom(untiltedZoom(zoom, FLAT_VIEW.pitch), TERRAIN_PITCH);
        zoom = tiltZoom(untiltedZoom(zoom, TERRAIN_PITCH), FLAT_VIEW.pitch);
      }
      expect(zoom).toBeCloseTo(13, 10);
    });
    it('keeps a pinch made in 3D, instead of losing it when the map flattens', () => {
      // Pinching while tilted changes the scale the flat view is measured in.
      const pinched = tiltZoom(13, TERRAIN_PITCH) + 0.8;
      expect(tiltZoom(untiltedZoom(pinched, TERRAIN_PITCH), FLAT_VIEW.pitch)).toBeCloseTo(13.8, 10);
    });
  });
});

describe('untiltedZoom', () => {
  it('is the inverse of tiltZoom at every tilt, not just the relief pitch', () => {
    for (const pitch of [0, 7.5, 30, 55, 85]) {
      expect(untiltedZoom(tiltZoom(12, pitch), pitch)).toBeCloseTo(12, 10);
    }
  });
  it('reads a flat camera as itself, so anchoring never moves a flat map', () => {
    expect(untiltedZoom(12, FLAT_VIEW.pitch)).toBe(12);
  });
  it('never falls below zero, unlike the clamped direction', () => {
    expect(untiltedZoom(0, TERRAIN_PITCH)).toBe(TERRAIN_ZOOM_OUT);
  });
});