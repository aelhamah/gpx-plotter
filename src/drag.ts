export function dragThresholdExceeded(dx: number, dy: number, threshold = 3): boolean {
  return Math.hypot(dx, dy) >= threshold;
}
