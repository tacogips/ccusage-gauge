import { describe, expect, test } from "bun:test";
import type { CostRow } from "../src/api";
import { currentViewMetricTotal } from "../src/currentViewMetrics";

const row = (costUSD: number, totalTokens: number): CostRow => ({
  timestamp: "2026-07-28T08:00:00Z",
  agent: "codex",
  model: "gpt-5.6",
  costUSD,
  inputTokens: totalTokens,
  outputTokens: 0,
  cacheCreationTokens: 0,
  cacheReadTokens: 0,
  totalTokens,
  dataQuality: "sessionEstimated",
  machine: "local",
});

describe("current view metric totals", () => {
  test("uses the filtered cost series that is rendered by the graph", () => {
    const visibleSeries = [row(20, 200), row(32, 320)];

    expect(currentViewMetricTotal(visibleSeries, "costUSD")).toBe(52);
    expect(currentViewMetricTotal(visibleSeries, "totalTokens")).toBe(520);
  });

  test("does not include rows removed by the current model or machine filters", () => {
    const visibleSeries = [row(20, 200)];

    expect(currentViewMetricTotal(visibleSeries, "costUSD")).toBe(20);
  });
});
