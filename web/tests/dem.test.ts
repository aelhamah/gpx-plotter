import { describe, it, expect } from 'vitest';
import { decodeElevations, slopeBandColorHex, slopeRgba } from '../src/dem';

describe('decodeElevations', () => {
  it('decodes the terrain-RGB formula', () => {
    // R=100, G=200, B=50 → -10000 + (100*65536 + 200*256 + 50) * 0.1
    const data = new Uint8ClampedArray([100, 200, 50, 255]);
    expect(decodeElevations(data)[0]).toBeCloseTo(650485, 7);
  });
  it('decodes ocean (all zeros) to -10000 m', () => {
    const data = new Uint8ClampedArray(4 * 2); // two transparent pixels
    expect(decodeElevations(data)[0]).toBe(-10000);
    expect(decodeElevations(data)[1]).toBe(-10000);
  });
});

/** A square grid whose elevation rises `perPixel` meters per row (a uniform ramp). */
function rampGrid(width: number, height: number, perPixel: number): Float32Array {
  const e = new Float32Array(width * height);
  for (let j = 0; j < height; j++) {
    for (let i = 0; i < width; i++) e[j * width + i] = j * perPixel;
  }
  return e;
}

describe('slopeRgba', () => {
  it('paints every pixel of the tile (regression: only the first rows were filled)', () => {
    const rgba = slopeRgba(rampGrid(64, 64, 500), 64, 64, 100);
    expect(rgba.length).toBe(64 * 64 * 4);
    for (const index of [0, 3, 63 * 64 * 4 + 3, (63 * 64 + 63) * 4 + 3]) {
      expect(rgba[index]).toBeGreaterThan(0); // never transparent
    }
  });
  it('saturates a genuinely steep ramp to a non-green band', () => {
    // Rise of 500 m per pixel over an 8-px gradient window at ppx=100:
    // slope = atan(4000 / 800) ≈ 79° → near-black/red, never green.
    const steep = slopeRgba(rampGrid(32, 32, 500), 32, 32, 100);
    const [r, g, b] = steep;
    expect(g).toBeLessThan(200); // not the <20° green [34,197,94]
  });
  it('flattens the same terrain to green when ppx is too large (meters-per-pixel unit bug)', () => {
    // Same DEM grid, but ppx 256× too big (as in the pre-fix code) → all slopes < 1° → green.
    const flat = slopeRgba(rampGrid(32, 32, 500), 32, 32, 100 * 256);
    expect(flat[0]).toBe(34);
    expect(flat[1]).toBe(197);
    expect(flat[2]).toBe(94);
  });
  it('maps slope bands to their colors at clear mid-band angles', () => {
    for (const [degrees, expected] of [
      [25, [234, 179, 8]],   // yellow (<30°)
      [32, [249, 115, 22]],  // orange (<35°)
      [42, [168, 85, 247]],  // purple (<45°)
    ] as [number, [number, number, number]][]) {
      // Linear ramp gives every pixel slope = atan(4·perPixel / (2·step·ppx)) = atan(perPixel / 200).
      const perPixel = 200 * Math.tan((degrees * Math.PI) / 180);
      const rgba = slopeRgba(rampGrid(64, 64, perPixel), 64, 64, 100);
      expect([rgba[0], rgba[1], rgba[2]], `at ${degrees}°`).toEqual(expected);
    }
  });
});

describe('slopeBandColorHex', () => {
  it('matches every avalanche band boundary used by the profile shader and legend', () => {
    for (const [degrees, expected] of [
      [0, '#22c55e'], // <20° green
      [19.9, '#22c55e'],
      [20, '#eab308'], // <30° yellow
      [29.9, '#eab308'],
      [30, '#f97316'], // <35° orange
      [34.9, '#f97316'],
      [35, '#ef4444'], // <40° red
      [39.9, '#ef4444'],
      [40, '#a855f7'], // <45° purple
      [44.9, '#a855f7'],
      [45, '#111827'], // 45°+ near-black
      [89, '#111827'],
    ] as [number, string][]) {
      expect(slopeBandColorHex(degrees), `at ${degrees}°`).toBe(expected);
    }
  });
});