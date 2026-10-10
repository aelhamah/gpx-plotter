import { describe, expect, it } from 'vitest';
import {
  FLAT_VIEW,
  RELIEF_VIEW,
  TERRAIN_EXAGGERATION,
  TERRAIN_PITCH,
  TERRAIN_TRANSITION_MS,
  easeInOutCubic,
  terrainAt,
  transitionProgress,
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