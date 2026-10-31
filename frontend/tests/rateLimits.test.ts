import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import type { ProviderRateLimits, RateLimitsResponse, RateLimitWindow } from "../src/api";
import { formatResetIn, normalizeHiddenPieRatios, normalizePieCharts, pieFraction, rateLimitStatusLabel, rateLimitWindowFor, toggleHiddenPieRatio, togglePieChart } from "../src/rateLimits";
const window: RateLimitWindow = { kind: "weekly", windowSeconds: 604800, usedPercent: 47, remainingPercent: 53 };
const provider: ProviderRateLimits = { provider: "codex", status: "ok", stale: false, weekly: window, otherWindows: [] };
const sample: RateLimitsResponse = { generatedAt: "2026-10-31T12:00:00Z", scope: "local", providers: [provider] };
const now = new Date("2026-10-31T12:00:00Z");
describe("rate limits", () => {
  test("normalizes and toggles selections", () => {
    expect(normalizePieCharts(undefined)).toEqual(["budget"]);
    expect(normalizePieCharts(["codexWeekly", "x", "claude5h", "claude5h"])).toEqual(["claude5h", "codexWeekly"]);
    expect(normalizePieCharts([])).toEqual(["budget"]);
    expect(togglePieChart("budget", ["budget"])).toEqual(["budget"]);
    expect(togglePieChart("codex5h", ["budget"])).toEqual(["budget", "codex5h"]);
  });
  test("normalizes and toggles hidden pie ratios", () => {
    expect(normalizeHiddenPieRatios(undefined)).toEqual([]);
    expect(normalizeHiddenPieRatios([])).toEqual([]);
    expect(normalizeHiddenPieRatios(["codexWeekly", "x", "budget", "budget"])).toEqual(["budget", "codexWeekly"]);
    expect(normalizeHiddenPieRatios("budget")).toEqual([]);
    expect(toggleHiddenPieRatio("budget", [])).toEqual(["budget"]);
    expect(toggleHiddenPieRatio("budget", ["budget"])).toEqual([]);
    expect(toggleHiddenPieRatio("claude5h", ["codexWeekly"])).toEqual(["claude5h", "codexWeekly"]);
  });
  test("maps windows and clamps fractions", () => {
    expect(rateLimitWindowFor("codexWeekly", sample).window).toEqual(window);
    expect(rateLimitWindowFor("codexWeekly", { ...sample, providers: [{ ...provider, weekly: null }] }).window).toBeNull();
    expect(pieFraction({ ...window, usedPercent: 120 })).toBe(1);
    expect(pieFraction(window)).toBe(0.47);
  });
  test("formats reset times", () => {
    expect(formatResetIn("2026-10-31T14:13:00Z", now)).toBe("resets in 2h 13m");
    expect(formatResetIn("2026-11-03T16:00:00Z", now)).toBe("resets in 3d 4h");
    expect(formatResetIn(null, now)).toBe("reset time unknown");
    expect(formatResetIn("bad", now)).toBe("reset time unknown");
    expect(formatResetIn("2026-10-31T11:59:00Z", now)).toBe("reset due");
  });
  test("labels each status", () => {
    expect(rateLimitStatusLabel(provider, now)).toBe("");
    expect(rateLimitStatusLabel({ ...provider, status: "unauthorized" }, now)).toBe("Sign in again with the CLI");
    expect(rateLimitStatusLabel({ ...provider, status: "unavailable", message: "Unavailable now" }, now)).toBe("Unavailable now");
    expect(rateLimitStatusLabel({ ...provider, status: "stale", fetchedAt: now.toISOString() }, now)).toBe(`as of ${now.toLocaleString()}`);
  });
  test("shields resource from dashboard failure state", () => {
    const source = readFileSync(new URL("../src/App.tsx", import.meta.url), "utf8");
    expect(source).toContain("shieldResource(rateLimitsResource)");
    expect(source).not.toContain("rateLimitsResource(");
    for (const marker of ["dashboardErrorMessage(", "hasFailedRequest:", "isFetching:"]) {
      const line = source.split("\n").find((item) => item.includes(marker));
      expect(line).toBeDefined();
      expect(line).not.toContain("rateLimits");
    }
  });
});
