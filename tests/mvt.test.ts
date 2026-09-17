import { describe, expect, it } from 'vitest';
import { decodeTile, layerByName, tilePointToLngLat } from '../src/mvt';
import { encodeTile } from './helpers/mvtEncode';

const EXTENT = 4096;

function trailFixture() {
  return encodeTile([
    {
      name: 'trail',
      extent: EXTENT,
      features: [
        { type: 2, props: { class: 'hiking', name: 'Elk Loop' }, parts: [[[100, 200], [140, 260], [180, 240]]] },
        { type: 2, props: { class: 'foot' }, parts: [[[10, 10], [20, 20]], [[50, 50], [60, 60]]] },
      ],
    },
    {
      name: 'mountain_peak',
      extent: EXTENT,
      features: [{ type: 1, props: { name: 'Mount Sentinel', ele: 2398 }, parts: [[[300, 400]]] }],
    },
  ]);
}

describe('decodeTile', () => {
  it('decodes layer names, extent, and feature properties', () => {
    const layers = decodeTile(trailFixture());
    expect(layers.length).toBe(2);

    expect(layerByName(layers, 'trail')).toBeDefined();
    expect(layerByName(layers, 'mountain_peak')).toBeDefined();
    expect(layerByName(layers, 'nope')).toBeUndefined();

    for (const layer of layers) expect(layer.extent).toBe(EXTENT);

    const trails = layers.find((layer) => layer.name === 'trail')!;
    expect(trails.features).toHaveLength(2);
    expect(trails.features[0].type).toBe(2);
    expect(trails.features[0].props).toEqual({ class: 'hiking', name: 'Elk Loop' });

    const peaks = layers.find((layer) => layer.name === 'mountain_peak')!;
    expect(peaks.features[0].props).toEqual({ name: 'Mount Sentinel', ele: 2398 });
  });

  it('decodes LineString geometry to exact tile pixels', () => {
    const layers = decodeTile(trailFixture());
    const trail = layers.find((layer) => layer.name === 'trail')!;
    expect(trail.features[0].parts).toEqual([[[100, 200], [140, 260], [180, 240]]]);
  });

  it('keeps MultiLineString parts separate', () => {
    const layers = decodeTile(trailFixture());
    const trail = layers.find((layer) => layer.name === 'trail')!;
    expect(trail.features[1].parts).toEqual([[[10, 10], [20, 20]], [[50, 50], [60, 60]]]);
  });

  it('decodes Point geometry and default extent 4096', () => {
    const bytes = encodeTile([{ name: 'mountain_peak', features: [{ type: 1, props: { name: 'P' }, parts: [[[1, 2]]] }] }]);
    const layers = decodeTile(bytes);
    const peaks = layerByName(layers, 'mountain_peak')!;
    expect(peaks.extent).toBe(4096);
    expect(peaks.features[0].parts).toEqual([[[1, 2]]]);
  });

  it('handles a closed polygon ring (ClosePath command)', () => {
    const bytes = encodeTile([
      {
        name: 'landuse',
        extent: EXTENT,
        features: [{ type: 3, props: { class: 'wood' }, parts: [[[0, 0], [100, 0], [100, 100], [0, 100]]], close: true }],
      },
    ]);
    const layers = decodeTile(bytes);
    const landuse = layerByName(layers, 'landuse')!;
    expect(landuse.features[0].parts).toEqual([[[0, 0], [100, 0], [100, 100], [0, 100]]]);
  });
});

describe('tilePointToLngLat', () => {
  it('maps tile pixels back to the correct world positions', () => {
    const z = 1;
    const x = 0;
    const y = 1; // bottom half
    const nw = tilePointToLngLat(z, x, y, EXTENT, 0, 0);
    expect(nw.lng).toBeCloseTo(-180, 5);
    expect(nw.lat).toBeCloseTo(0, 5);

    const se = tilePointToLngLat(z, x, y, EXTENT, EXTENT, EXTENT);
    expect(se.lng).toBeCloseTo(0, 5);
    expect(se.lat).toBeCloseTo(-85.05, 1);

    const center = tilePointToLngLat(z, x, y, EXTENT, EXTENT / 2, EXTENT / 2);
    expect(center.lng).toBeCloseTo(-90, 5);
  });
});