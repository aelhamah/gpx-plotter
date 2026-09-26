import { describe, it, expect } from 'vitest';
import { ROUTE_COLORS, TRACE_COLOR, routeColorForId } from '../src/colors';

describe('route color palette', () => {
  it('keeps the hover trace color globally unique from the route defaults', () => {
    expect(ROUTE_COLORS).not.toContain(TRACE_COLOR);
  });
  it('gives every route a distinct default color', () => {
    expect(new Set(ROUTE_COLORS).size).toBe(ROUTE_COLORS.length);
  });
  it('keeps the trace blue despite route 2 taking a new color', () => {
    expect(TRACE_COLOR).toBe('#0ea5e9');
    expect(ROUTE_COLORS[1]).not.toBe('#0ea5e9');
  });
  it('assigns colors deterministically by id', () => {
    expect(routeColorForId(1)).toBe(ROUTE_COLORS[0]);
    expect(routeColorForId(2)).toBe(ROUTE_COLORS[1]);
    expect(routeColorForId(3)).toBe(ROUTE_COLORS[2]);
    expect(routeColorForId(ROUTE_COLORS.length + 1)).toBe(ROUTE_COLORS[0]);
  });
  it('never assigns route 2 the trace color', () => {
    expect(routeColorForId(2)).not.toBe(TRACE_COLOR);
  });
});