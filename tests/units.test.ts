import { describe, it, expect } from 'vitest';
import { defaultUnitSystem, formatDistance, formatDistanceAxis, formatElevation, formatSlope } from '../src/units';

describe('formatDistance', () => {
  it('formats miles vs kilometers', () => {
    expect(formatDistance(1609.344, 'imperial')).toBe('1.00 mi');
    expect(formatDistance(1609.344, 'metric')).toBe('1.61 km');
  });
});

describe('formatElevation', () => {
  it('formats feet vs meters and handles missing values', () => {
    expect(formatElevation(1000, 'imperial')).toBe('3,281 ft');
    expect(formatElevation(1000, 'metric')).toBe('1,000 m');
    expect(formatElevation(undefined, 'metric')).toBe('—');
  });
});

describe('formatSlope', () => {
  it('formats degrees and handles missing values', () => {
    expect(formatSlope(42.3)).toBe('42°');
    expect(formatSlope(undefined)).toBe('—');
  });
});

describe('formatDistanceAxis', () => {
  it('uses one decimal below 10 units and rounds above', () => {
    expect(formatDistanceAxis(2023, 'imperial')).toBe('1.3');
    expect(formatDistanceAxis(30 * 1609.344, 'imperial')).toBe('30');
    expect(formatDistanceAxis(1500, 'metric')).toBe('1.5');
    expect(formatDistanceAxis(15000, 'metric')).toBe('15');
  });
});

describe('defaultUnitSystem', () => {
  it('always resolves to a valid unit system', () => {
    expect(['metric', 'imperial']).toContain(defaultUnitSystem());
  });
});