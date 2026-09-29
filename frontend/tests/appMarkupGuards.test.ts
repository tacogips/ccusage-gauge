import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const app = readFileSync(join(import.meta.dir, "../src/App.tsx"), "utf8");
const chart = readFileSync(join(import.meta.dir, "../src/UsageChart.tsx"), "utf8");
const rangeControls = readFileSync(join(import.meta.dir, "../src/RangeControls.tsx"), "utf8");
const layout = readFileSync(join(import.meta.dir, "../src/DashboardLayout.tsx"), "utf8");
const html = readFileSync(join(import.meta.dir, "../index.html"), "utf8");

describe("dashboard app markup contract", () => {
  test("uses square SVG rectangles", () => {
    const radii = [...chart.matchAll(/\brx="([^"]+)"/g)].map((match) => match[1]);
    expect(radii.length).toBeGreaterThan(0);
    expect(radii.every((radius) => radius === "0")).toBe(true);
  });

  test("has no light/dark scheme selection or persistence", () => {
    for (const removedThemeHook of [
      "colorScheme",
      "dataset.colorScheme",
      "ccusage-gauge-color-scheme",
      "prefers-color-scheme",
    ]) expect(app).not.toContain(removedThemeHook);
    expect(html).toContain('<meta name="color-scheme" content="dark" />');
  });

  test("wires pressed range, stack, and fold semantics", () => {
    expect(rangeControls).toContain("range-buttons toggle-group");
    expect(rangeControls).toContain('aria-pressed={rangeButtonPressed(props.range(), value) ? "true" : "false"}');
    expect(rangeControls).toContain('aria-pressed={rangeButtonPressed(props.range(), "custom") ? "true" : "false"}');
    expect(app).toContain('"modelEffort"');
    expect(app).toContain("sidebarCollapsed");
    expect(app).toContain("headerCollapsed");
    expect(layout).toContain('aria-controls="usage-filters-content"');
    expect(layout).toContain('aria-controls="dashboard-header-content"');
    for (const label of ["Collapse filters", "Expand filters", "Collapse header", "Expand header"])
      expect(layout).toContain(label);
  });
});
