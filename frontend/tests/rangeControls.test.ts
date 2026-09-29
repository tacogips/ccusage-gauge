import { describe, expect, test } from "bun:test";
import { quickRanges, rangeButtonPressed, rangeSummaryLabel, type Range } from "../src/rangeControls.ts";

describe("range controls", () => {
  test("presses only the matching preset", () => {
    expect(rangeButtonPressed("today", "today")).toBe(true);
    expect(rangeButtonPressed("today", "yesterday")).toBe(false);
  });

  test("presses Custom only for a custom range", () => {
    const current: Range = "custom";
    expect(quickRanges.every(([range]) => !rangeButtonPressed(current, range))).toBe(true);
    expect(rangeButtonPressed(current, "custom")).toBe(true);
    expect(rangeButtonPressed("today", "custom")).toBe(false);
  });

  test("restored preset state presses only that preset", () => {
    const pressed = quickRanges
      .filter(([range]) => rangeButtonPressed("week", range))
      .map(([range]) => range);
    expect(pressed).toEqual(["week"]);
  });

  test("summarizes preset and custom ranges", () => {
    expect(rangeSummaryLabel("today", { start: "2026-09-30", end: "2026-09-30" })).toBe("Today");
    expect(rangeSummaryLabel("custom", { start: "2026-09-01", end: "2026-09-07" }))
      .toBe("Custom 2026-09-01 to 2026-09-07");
  });
});
