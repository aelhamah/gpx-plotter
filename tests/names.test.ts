import { describe, it, expect } from 'vitest';
import { normalizeRouteName, normalizeWaypointName } from '../src/names';

describe('normalizeRouteName', () => {
  it('keeps a real name (trimmed)', () => {
    expect(normalizeRouteName('  Maroon Bells  ', 7)).toBe('Maroon Bells');
  });
  it('falls back to the auto id name when blank', () => {
    expect(normalizeRouteName('', 3)).toBe('Route 3');
    expect(normalizeRouteName('   ', 3)).toBe('Route 3');
  });
});

describe('normalizeWaypointName', () => {
  it('keeps a real name (trimmed)', () => {
    expect(normalizeWaypointName(' Stream crossing ', 0)).toBe('Stream crossing');
  });
  it('falls back to the auto id name when blank', () => {
    expect(normalizeWaypointName('', 2)).toBe('Waypoint 3');
    expect(normalizeWaypointName(' \t ', 0)).toBe('Waypoint 1');
  });
});