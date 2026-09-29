export type QuickRange = "recent12h" | "today" | "yesterday" | "week" | "month";
export type Range = QuickRange | "custom";

export const quickRanges: Array<[QuickRange, string]> = [
  ["recent12h", "Last 12 hours"],
  ["today", "Today"],
  ["yesterday", "Yesterday"],
  ["week", "This week"],
  ["month", "This month"],
];

export function rangeButtonPressed(current: Range, button: Range): boolean {
  return current === button;
}

export function rangeSummaryLabel(
  range: Range,
  applied: { start: string; end: string },
): string {
  return range === "custom"
    ? `Custom ${applied.start} to ${applied.end}`
    : quickRanges.find(([value]) => value === range)?.[1] ?? "Selected period";
}
