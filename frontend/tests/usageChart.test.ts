import { describe, expect, test } from "bun:test";
import { clippedInterval } from "../src/usageChartGeometry";

describe("usage chart observability overlays", () => {
  test("clips a gap to both visible domain boundaries", () => {
    expect(clippedInterval(
      "2026-07-23T22:00:00.000Z",
      "2026-07-24T01:00:00.000Z",
      Date.parse("2026-07-23T23:00:00.000Z"),
      Date.parse("2026-07-24T00:00:00.000Z"),
    )).toEqual({
      startAt: "2026-07-23T23:00:00.000Z",
      endAt: "2026-07-24T00:00:00.000Z",
    });
  });

  test("omits gaps entirely outside the domain", () => {
    expect(clippedInterval(
      "2026-07-23T20:00:00.000Z",
      "2026-07-23T21:00:00.000Z",
      Date.parse("2026-07-23T23:00:00.000Z"),
      Date.parse("2026-07-24T00:00:00.000Z"),
    )).toBeUndefined();
  });
});
