import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const css = readFileSync(fileURLToPath(new URL('../src/style.css', import.meta.url)), 'utf8');

interface Rule {
  selectors: string[];
  pointerEvents?: string;
}

/** Flat list of `selector { ... }` rules in source order (no nesting in this file). */
function rules(): Rule[] {
  return css
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .split('}')
    .map((block) => {
      const brace = block.indexOf('{');
      if (brace === -1) return null;
      const selectors = block.slice(0, brace).split(',').map((s) => s.trim()).filter(Boolean);
      const match = /pointer-events\s*:\s*([^;]+)/.exec(block.slice(brace));
      return { selectors, pointerEvents: match ? match[1].trim() : undefined } satisfies Rule;
    })
    .filter((rule): rule is Rule => rule !== null);
}

const all = rules();

/** Last `pointer-events` declared for an exact selector, or undefined if never set. */
function declaredFor(selector: string): string | undefined {
  let value: string | undefined;
  for (const rule of all) {
    if (rule.selectors.includes(selector) && rule.pointerEvents !== undefined) value = rule.pointerEvents;
  }
  return value;
}

/**
 * `pointer-events` inherits, so a control nested inside a click-through block is
 * dead unless it opts back in. Walk the real ancestor chain and resolve the
 * effective value.
 */
function effectivePointerEvents(chain: string[]): string | undefined {
  let value: string | undefined;
  for (const selector of chain) {
    const declared = declaredFor(selector);
    if (declared !== undefined) value = declared;
  }
  return value;
}

describe('sidebar click-through backdrop', () => {
  it('keeps the units toggle clickable inside the click-through brand block', () => {
    // Regression: `.sidebar .brand` is `pointer-events: none` so the map can be
    // dragged under the title, which made the Metric/Imperial buttons dead —
    // presses fell through to the map and panned it instead.
    expect(declaredFor('.sidebar')).toBe('none');
    expect(effectivePointerEvents(['.sidebar', '.sidebar .brand', '.sidebar .brand .units-toggle'])).toBe('auto');
  });

  it('leaves the text-only sidebar blocks click-through', () => {
    for (const selector of ['.sidebar .brand', '.sidebar #map-status', '.sidebar .help', '.sidebar .stats']) {
      expect(declaredFor(selector)).toBe('none');
    }
  });

  it('restores pointer events for interactive sidebar sections', () => {
    expect(effectivePointerEvents(['.sidebar', '.sidebar > *'])).toBe('auto');
  });
});
