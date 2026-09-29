import { describe, expect, test } from "bun:test";
import { clippedInterval } from "../src/usageChartGeometry";
import {
  compareSeriesIdentities,
  chartSeriesIdentity,
  chartSeriesLabel,
  directorySeriesDisplayLabel,
  modelEffortParts,
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

describe("modelEffort series", () => {
  const row: CostRow = {
    timestamp: "2026-07-16T00:00:00Z",
    agent: "codex",
    model: "gpt-6-luna",
    costUSD: 1,
    inputTokens: 1,
    outputTokens: 2,
    cacheCreationTokens: 0,
    cacheReadTokens: 3,
    totalTokens: 6,
    dataQuality: "timestamped",
    machine: "local",
  };

  test("identifies, labels, and splits known and unknown effort at the last separator", () => {
    const known = { ...row, effort: "high" };
    expect(chartSeriesIdentity(known, "modelEffort")).toBe("gpt-6-luna\u001fhigh");
    expect(chartSeriesLabel(known, "modelEffort", () => "unused"))
      .toBe("gpt-6-luna (high)");

    const unknown = chartSeriesIdentity(row, "modelEffort");
    expect(unknown).toBe("gpt-6-luna\u001f");
    expect(chartSeriesLabel(row, "modelEffort", () => "unused"))
      .toBe("gpt-6-luna (unknown)");
    expect(modelEffortParts(unknown)).toEqual({ model: "gpt-6-luna" });
    expect(modelEffortParts("model\u001fvariant\u001fmedium"))
      .toEqual({ model: "model\u001fvariant", effort: "medium" });
  });

  test("sorts by model, then known effort rank, unranked text, and unknown last", () => {
    const identities = ["xhigh", "", "low", "turbo", "high"]
      .map((effort) => `gpt-6-luna\u001f${effort}`);
    expect(identities.sort((a, b) => compareSeriesIdentities("modelEffort", a, b)))
      .toEqual(["low", "high", "xhigh", "turbo", ""].map((effort) => `gpt-6-luna\u001f${effort}`));

    const models = ["gpt-6-sol\u001fhigh", "gpt-6-luna\u001fminimal"];
    expect(models.sort((a, b) => compareSeriesIdentities("modelEffort", a, b)))
      .toEqual(["gpt-6-luna\u001fminimal", "gpt-6-sol\u001fhigh"]);
  });

  test("preserves each model total when its effort series are summed", () => {
    const rows: CostRow[] = [
      { ...row, effort: "high", costUSD: 2 },
      { ...row, effort: "low", costUSD: 3 },
      { ...row, effort: undefined, costUSD: 5 },
    ];
    const totalsFor = (stackBy: "model" | "modelEffort") => rows.reduce<Record<string, number>>(
      (totals, item) => {
        const identity = chartSeriesIdentity(item, stackBy);
        totals[identity] = (totals[identity] ?? 0) + item.costUSD;
        return totals;
      },
      {},
    );
    const modelTotals = totalsFor("model");
    const modelEffortTotals = totalsFor("modelEffort");
    expect(Object.values(modelEffortTotals).reduce((sum, value) => sum + value, 0))
      .toBe(modelTotals["gpt-6-luna"]);
    expect(Object.keys(modelEffortTotals).sort()).toEqual([
      "gpt-6-luna\u001f",
      "gpt-6-luna\u001fhigh",
      "gpt-6-luna\u001flow",
    ]);
  });
});
