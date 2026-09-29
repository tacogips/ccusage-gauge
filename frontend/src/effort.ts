export const EFFORT_ORDER = ["minimal", "low", "medium", "high", "xhigh"] as const;
export const UNKNOWN_EFFORT = "unknown";

export function effortRank(effort?: string): number {
  if (effort === undefined || effort === "") return EFFORT_ORDER.length + 1;
  const rank = (EFFORT_ORDER as readonly string[]).indexOf(effort);
  return rank >= 0 ? rank : EFFORT_ORDER.length;
}

export function effortLabel(effort?: string): string {
  return effort === undefined || effort === "" ? UNKNOWN_EFFORT : effort;
}
