import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const app = readFileSync(join(import.meta.dir, "../src/App.tsx"), "utf8");
const piePanel = readFileSync(join(import.meta.dir, "../src/PieChartPanel.tsx"), "utf8");
const chart = readFileSync(join(import.meta.dir, "../src/UsageChart.tsx"), "utf8");
const rangeControls = readFileSync(join(import.meta.dir, "../src/RangeControls.tsx"), "utf8");
const layout = readFileSync(join(import.meta.dir, "../src/DashboardLayout.tsx"), "utf8");
const html = readFileSync(join(import.meta.dir, "../index.html"), "utf8");

describe("dashboard app markup contract", () => {
  test("wires per-pie ratio text visibility", () => {
    expect(piePanel).toContain("<Show when={ratioVisible()}><span>{detail()}</span></Show>");
    expect(piePanel).toContain("aria-pressed={ratioVisible()}");
    expect(piePanel).toContain("Show ratio text for ");
    expect(piePanel).toContain("props.onToggleRatio(id)");
    expect(piePanel).toContain("props.hiddenRatios()");
    expect(piePanel).toContain('aria-label={`${labels[id]}: ${detail()}`}');
    expect(app).toContain("setHiddenPieRatios(normalizeHiddenPieRatios(state.hiddenPieRatios))");
    expect(app).toContain("hiddenPieRatios: hiddenPieRatios(),");
    expect(app).toContain("Menu budget: ");
  });

  test("uses square SVG rectangles", () => {
    const radii = [...chart.matchAll(/\brx="([^"]+)"/g)].map((match) => match[1]);
    expect(radii.length).toBeGreaterThan(0);
    expect(radii.every((radius) => radius === "0")).toBe(true);
  });

  test("offers an explicit light theme while dark stays the default", () => {
    expect(app).toContain("<ThemeToggle scheme={colorScheme()} onToggle={toggleColorScheme} />");
    expect(app).toContain("readStoredColorScheme()");
    expect(layout).toContain('"Switch to light theme"');
    expect(layout).toContain('"Switch to dark theme"');
    for (const legacyThemeHook of ["dataset.colorScheme", "ccusage-gauge-color-scheme", "prefers-color-scheme"])
      expect(app + layout).not.toContain(legacyThemeHook);
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
