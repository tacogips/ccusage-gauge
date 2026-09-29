import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "../src/styles.css"), "utf8");
const rootMatch = css.match(/^:root\s*\{([^}]*)\}/);
const root = rootMatch?.[1] ?? "";

function token(name: string): string {
  const value = root.match(new RegExp(`${name}:\\s*(#[0-9a-fA-F]{6})`))?.[1];
  if (!value) throw new Error(`Missing six-digit root token ${name}`);
  return value;
}

function luminance(hex: string): number {
  const channels = hex.slice(1).match(/../g)?.map((channel) => Number.parseInt(channel, 16) / 255) ?? [];
  const [red, green, blue] = channels.map((channel) =>
    channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4,
  );
  return 0.2126 * red + 0.7152 * green + 0.0722 * blue;
}

function contrast(first: string, second: string): number {
  const values = [luminance(first), luminance(second)].sort((a, b) => b - a);
  return (values[0] + 0.05) / (values[1] + 0.05);
}

describe("dark flat stylesheet contract", () => {
  test("uses square geometry and removes effects and theme overrides", () => {
    const radiusValues = [...css.matchAll(/border-radius\s*:\s*([^;}]+)/g)].map((match) => match[1].trim());
    expect(radiusValues.every((value) => value === "0" || value === "0px")).toBe(true);
    expect(css.match(/(?:box-shadow|text-shadow)\s*:\s*(?!none\s*[;}])[^;}]+/g) ?? []).toEqual([]);
    expect(css).not.toMatch(/gradient\s*\(/i);
    expect(css).not.toMatch(/drop-shadow/i);
    expect(css).not.toMatch(/data-color-scheme/i);
  });

  test("declares dark theme tokens and the fold and pressed-state hooks", () => {
    expect(css.startsWith(":root {")).toBe(true);
    for (const contract of [
      "color-scheme: dark",
      "--color-bg: #0f1115",
      "--color-surface: #15171c",
      "--color-control-border",
      "--color-chart-axis",
      '.toggle-group button[aria-pressed="true"]',
      ".sidebar-collapsed",
      ".pane-fold-bar",
      ".header-collapsed",
      ".header-fold-toggle",
      "button:hover:not(:disabled)",
      "button:focus-visible",
      "button:active",
      "button:disabled",
    ]) expect(css).toContain(contract);
    expect(css.match(/\.toggle-group button\[aria-pressed="true"\]/g)?.length).toBe(1);
  });

  test("keeps color literals only in the initial root token block", () => {
    expect(rootMatch).not.toBeNull();
    const outsideRoot = css.replace(rootMatch?.[0] ?? "", "");
    expect(outsideRoot.match(/#[0-9a-fA-F]{3,8}\b|\brgba?\s*\(/gi) ?? []).toEqual([]);
  });

  test("meets the specified text, control, chart, and separator contrast ratios", () => {
    const bg = token("--color-bg");
    const surface = token("--color-surface");
    const raised = token("--color-surface-raised");
    const border = token("--color-border");
    const controlBorder = token("--color-control-border");
    const text = token("--color-text");
    const muted = token("--color-text-muted");
    const accent = token("--color-accent");
    const accentText = token("--color-accent-text");
    const chartAxis = token("--color-chart-axis");
    expect(raised).toBeTruthy();
    expect(contrast(text, bg)).toBeGreaterThanOrEqual(4.5);
    expect(contrast(text, surface)).toBeGreaterThanOrEqual(4.5);
    expect(contrast(muted, surface)).toBeGreaterThanOrEqual(3);
    expect(contrast(accentText, accent)).toBeGreaterThanOrEqual(4.5);
    expect(contrast(controlBorder, surface)).toBeGreaterThanOrEqual(3);
    expect(contrast(controlBorder, bg)).toBeGreaterThanOrEqual(3);
    expect(contrast(chartAxis, surface)).toBeGreaterThanOrEqual(3);
    expect(contrast(border, surface)).toBeGreaterThanOrEqual(1.5);
  });
});
