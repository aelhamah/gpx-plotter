/**
 * Pure routing along a set of trail polylines. Used to make a drawn route run
 * *along* a trail between two snapped points instead of cutting straight across.
 *
 * The polylines come from vector tiles; a single OSM way is often split into
 * several features, so loose endpoints within `JOIN_METERS` are bridged. A
 * Dijkstra search then finds the shortest chain of trail vertices between the
 * two points. Anything that is not meaningfully shorter than a straight line
 * (or simply unreachable) returns `null`, leaving the caller to draw straight.
 */

import { distanceMeters, nearestLine, type SnapPoint } from './snap';

/** Loose trail ends closer than this are treated as connected (way splits). */
export const TRAIL_JOIN_METERS = 25;
/** Refuse a routed path longer than this multiple of the straight-line distance. */
export const TRAIL_MAX_DETOUR = 4;
const MAX_VERTICES = 20000;

interface Edge {
  to: number;
  w: number;
}

function coordKey(p: SnapPoint): string {
  return `${p.lat.toFixed(6)},${p.lon.toFixed(6)}`;
}

/** Drop exact-duplicate polylines (the same trail can appear in two tilesets). */
export function dedupeTrailLines(lines: SnapPoint[][]): SnapPoint[][] {
  const seen = new Set<string>();
  const out: SnapPoint[][] = [];
  for (const line of lines) {
    if (line.length < 2) continue;
    const key = line.map(coordKey).join('|');
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(line);
  }
  return out;
}

class MinHeap {
  private items: { node: number; dist: number }[] = [];

  push(node: number, dist: number): void {
    this.items.push({ node, dist });
    let i = this.items.length - 1;
    while (i > 0) {
      const parent = (i - 1) >> 1;
      if (this.items[parent].dist <= this.items[i].dist) break;
      [this.items[parent], this.items[i]] = [this.items[i], this.items[parent]];
      i = parent;
    }
  }

  pop(): { node: number; dist: number } | undefined {
    if (this.items.length === 0) return undefined;
    const top = this.items[0];
    const last = this.items.pop()!;
    if (this.items.length > 0) {
      this.items[0] = last;
      let i = 0;
      for (;;) {
        const left = i * 2 + 1;
        const right = left + 1;
        let smallest = i;
        if (left < this.items.length && this.items[left].dist < this.items[smallest].dist) smallest = left;
        if (right < this.items.length && this.items[right].dist < this.items[smallest].dist) smallest = right;
        if (smallest === i) break;
        [this.items[smallest], this.items[i]] = [this.items[i], this.items[smallest]];
        i = smallest;
      }
    }
    return top;
  }

  get size(): number {
    return this.items.length;
  }
}

/**
 * Shortest path along the trail network from `start` to `end`, both taken as
 * already-projected points on the network. Returns the vertex chain (starting
 * and ending at the projections), or `null` when there is no useful path.
 */
export function routeAlongTrails(lines: SnapPoint[][], start: SnapPoint, end: SnapPoint): SnapPoint[] | null {
  const unique = dedupeTrailLines(lines);
  if (unique.length === 0) return null;

  const nodes: SnapPoint[] = [];
  const nodeIndex = new Map<string, number>();
  const edges: Edge[][] = [];
  const endpoints: number[] = [];

  const addNode = (p: SnapPoint): number => {
    const key = coordKey(p);
    let index = nodeIndex.get(key);
    if (index === undefined) {
      index = nodes.length;
      nodeIndex.set(key, index);
      nodes.push(p);
      edges.push([]);
    }
    return index;
  };
  const addEdges = (i: number, j: number): void => {
    if (i === j) return;
    edges[i].push({ to: j, w: distanceMeters(nodes[i], nodes[j]) });
  };

  let vertices = 0;
  for (const line of unique) {
    let previous = -1;
    for (const point of line) {
      const index = addNode(point);
      if (previous >= 0) {
        addEdges(previous, index);
        addEdges(index, previous);
      }
      previous = index;
      vertices++;
    }
    endpoints.push(addNode(line[0]), addNode(line[line.length - 1]));
    if (vertices > MAX_VERTICES) return null;
  }

  // Bridge loose way endpoints so a split OSM way still routes as one trail.
  const uniqueEndpoints = [...new Set(endpoints)];
  for (let i = 0; i < uniqueEndpoints.length; i++) {
    for (let j = i + 1; j < uniqueEndpoints.length; j++) {
      const a = uniqueEndpoints[i];
      const b = uniqueEndpoints[j];
      if (distanceMeters(nodes[a], nodes[b]) <= TRAIL_JOIN_METERS) {
        addEdges(a, b);
        addEdges(b, a);
      }
    }
  }

  const startMatch = nearestLine(start, unique, Infinity);
  const endMatch = nearestLine(end, unique, Infinity);
  if (!startMatch?.result.segment || !endMatch?.result.segment) return null;
  if (distanceMeters(startMatch.result.point, endMatch.result.point) < 1) return null;

  const source = addNode(startMatch.result.point);
  const target = addNode(endMatch.result.point);
  for (const match of [startMatch, endMatch]) {
    const index = match === startMatch ? source : target;
    for (const bridge of [match.result.segment!.a, match.result.segment!.b]) {
      const node = addNode(bridge);
      addEdges(index, node);
      addEdges(node, index);
    }
  }
  if (source === target) return null;

  const dist = new Array<number>(nodes.length).fill(Infinity);
  const prev = new Array<number>(nodes.length).fill(-1);
  const settled = new Array<boolean>(nodes.length).fill(false);
  dist[source] = 0;
  const heap = new MinHeap();
  heap.push(source, 0);
  while (heap.size > 0) {
    const current = heap.pop()!;
    if (settled[current.node]) continue;
    settled[current.node] = true;
    if (current.node === target) break;
    for (const edge of edges[current.node]) {
      const next = current.dist + edge.w;
      if (next < dist[edge.to]) {
        dist[edge.to] = next;
        prev[edge.to] = current.node;
        heap.push(edge.to, next);
      }
    }
  }
  if (!Number.isFinite(dist[target])) return null;

  const straight = distanceMeters(startMatch.result.point, endMatch.result.point);
  if (dist[target] > TRAIL_MAX_DETOUR * straight) return null;

  const path: SnapPoint[] = [];
  for (let node = target; node !== -1; node = prev[node]) path.push(nodes[node]);
  path.reverse();
  return path;
}
