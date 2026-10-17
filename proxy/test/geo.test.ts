import { describe, expect, it } from 'vitest';
import { geoFromCf } from '../src/geo';

/**
 * The parsing, not the wiring.
 *
 * `request.cf` is a bag of optional strings assembled by a network hop, and every
 * way it can be wrong is a way this function has to answer "no" rather than hand
 * back a position that looks usable. The Worker test covers the route; this
 * covers the judgement.
 */

const ANN_ARBOR = { latitude: '42.2808', longitude: '-83.7430', city: 'Ann Arbor', country: 'US' };

describe('geoFromCf', () => {
  it('reads a city estimate out of the edge properties', () => {
    expect(geoFromCf(ANN_ARBOR)).toEqual({
      lat: 42.2808,
      lon: -83.743,
      city: 'Ann Arbor',
      country: 'US',
      precision: 'city',
    });
  });

  it('says how wrong it might be, in the payload', () => {
    // A client that puts this on screen has to be able to say it is a city-level
    // guess rather than a fix, and the only way it can is if it is told.
    expect(geoFromCf(ANN_ARBOR)?.precision).toBe('city');
  });

  it('accepts numbers as well as the strings the edge sends', () => {
    expect(geoFromCf({ latitude: 42.2808, longitude: -83.743 })).toMatchObject({ lat: 42.2808, lon: -83.743 });
  });

  describe('when there is no usable answer', () => {
    /**
     * Null rather than `(0, 0)`. That is a real place in the Gulf of Guinea, and a
     * plausible-looking one: a client that cannot tell "Cloudflare did not say"
     * from "Cloudflare said zero" has nothing to fall back to.
     */
    it('returns null rather than a zeroed position when the edge said nothing', () => {
      expect(geoFromCf(undefined)).toBeNull();
      expect(geoFromCf(null)).toBeNull();
      expect(geoFromCf({})).toBeNull();
    });

    it('returns null when only one coordinate is present', () => {
      expect(geoFromCf({ latitude: '42.2808' })).toBeNull();
      expect(geoFromCf({ longitude: '-83.7430' })).toBeNull();
    });

    it('returns null rather than treating a missing half as zero', () => {
      // Zero is a legal coordinate, so defaulting to it would silently put the
      // caller in the Gulf of Guinea / off West Africa instead of admitting the
      // answer was incomplete.
      expect(geoFromCf({ latitude: '42.2808', longitude: '' })).toBeNull();
      expect(geoFromCf({ latitude: '42.2808' })).not.toMatchObject({ lat: 0, lon: 0 });
    });

    it('returns null for anything that is not a number', () => {
      expect(geoFromCf({ latitude: 'north', longitude: '-83.7430' })).toBeNull();
      expect(geoFromCf({ latitude: '42.2808', longitude: null })).toBeNull();
      expect(geoFromCf({ latitude: '42.2808', longitude: { n: 1 } })).toBeNull();
      expect(geoFromCf({ latitude: 'NaN', longitude: '-83.7430' })).toBeNull();
      expect(geoFromCf({ latitude: 'Infinity', longitude: '-83.7430' })).toBeNull();
    });

    /**
     * An out-of-range coordinate would become a centre the map cannot render at
     * all, which is a worse outcome than falling back to the default.
     */
    it('returns null for a coordinate off the planet', () => {
      expect(geoFromCf({ latitude: '91', longitude: '0' })).toBeNull();
      expect(geoFromCf({ latitude: '0', longitude: '181' })).toBeNull();
      expect(geoFromCf({ latitude: '-91', longitude: '0' })).toBeNull();
    });

    it('accepts the extremes, which are real places', () => {
      expect(geoFromCf({ latitude: '90', longitude: '180' })).toMatchObject({ lat: 90, lon: 180 });
      expect(geoFromCf({ latitude: '-90', longitude: '-180' })).toMatchObject({ lat: -90, lon: -180 });
    });
  });

  it('omits a place name rather than reporting it as an empty string', () => {
    // Cloudflare sends `""` for fields it does not have. An empty `city` in the
    // payload reads as "the city is called nothing", which is a different and
    // wrong statement.
    const estimate = geoFromCf({ latitude: '42.2808', longitude: '-83.743', city: '', country: '  ' });
    expect(estimate).not.toBeNull();
    expect(estimate?.city).toBeUndefined();
    expect(estimate?.country).toBeUndefined();
  });

  it('trims the place names it does keep', () => {
    expect(geoFromCf({ latitude: '42.2808', longitude: '-83.743', city: ' Ann Arbor ' })?.city).toBe('Ann Arbor');
  });
});