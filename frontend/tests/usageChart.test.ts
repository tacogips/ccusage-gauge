import { describe, expect, test } from "bun:test";
import { clippedInterval } from "../src/usageChartGeometry";
import {
  chartSeriesIdentity,
  chartSeriesLabel,
  directorySeriesDisplayLabel,
} from "../src/usageChartSeries";
import type { CostRow } from "../src/api";

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

describe("usage chart directory series", () => {
  const row: CostRow = {
    timestamp: "2026-07-16T00:00:00Z",
    agent: "codex",
    model: "gpt",
    costUSD: 1,
    inputTokens: 1,
    outputTokens: 2,
    cacheCreationTokens: 0,
    cacheReadTokens: 3,
    totalTokens: 6,
    dataQuality: "timestamped",
    machine: "local",
    directory: "/work/project",
  };

  test("preserves existing model and machine series identities when split is off", () => {
    expect(chartSeriesIdentity(row, "model")).toBe("gpt");
    expect(chartSeriesIdentity(row, "machine")).toBe("local");
  });

  test("uses machine and full directory for subdirectory identity but a presentation label", () => {
    expect(chartSeriesIdentity(row, "subdirectory")).toBe("local\u001f/work/project");
    expect(chartSeriesLabel(row, "subdirectory", () => "project")).toBe("project");
  });

  test("separates equal directories by machine while global labels need no qualification", () => {
    const remote = { ...row, machine: "remote" };

    expect(chartSeriesIdentity(remote, "subdirectory"))
      .not.toBe(chartSeriesIdentity(row, "subdirectory"));
    expect(directorySeriesDisplayLabel(row, "project", "Laptop", false)).toBe("project");
    expect(directorySeriesDisplayLabel(row, "project-2", "Laptop", true)).toBe("project-2");
    expect(directorySeriesDisplayLabel(
      { ...remote, directory: undefined },
      undefined,
      "Server",
      true,
    )).toBe("Server: No directory");
  });
});
