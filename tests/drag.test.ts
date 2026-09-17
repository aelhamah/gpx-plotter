import { describe, expect, it } from 'vitest';
import { dragThresholdExceeded } from '../src/drag';

describe('dragThresholdExceeded', () => {
  it('does not exceed for small movement', () => {
    expect(dragThresholdExceeded(1, 1)).toBe(false);
    expect(dragThresholdExceeded(2, 0)).toBe(false);
    expect(dragThresholdExceeded(1, 2)).toBe(false);
  });
  it('exceeds at threshold', () => {
    expect(dragThresholdExceeded(3, 0)).toBe(true);
    expect(dragThresholdExceeded(0, 3)).toBe(true);
  });
  it('exceeds for larger movement', () => {
    expect(dragThresholdExceeded(10, 10)).toBe(true);
    expect(dragThresholdExceeded(5, 0)).toBe(true);
  });
  it('respects custom threshold', () => {
    expect(dragThresholdExceeded(4, 0, 5)).toBe(false);
    expect(dragThresholdExceeded(5, 0, 5)).toBe(true);
  });
});
