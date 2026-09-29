import { describe, expect, test } from "bun:test";
import {
  allocateModelColors,
  CHART_BACKGROUND,
  effortShade,
  MODEL_COLOR_FAMILIES,
  seriesColor,
  vendorForModel,
  type ModelVendor,
} from "../src/seriesColors";

function rgb(hex: string): [number, number, number] {
  return [1, 3, 5].map((offset) => Number.parseInt(hex.slice(offset, offset + 2), 16) / 255) as [number, number, number];
}

function linearize(channel: number): number {
  return channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4;
}

function xyz(hex: string): [number, number, number] {
  const [red, green, blue] = rgb(hex).map(linearize) as [number, number, number];
  return [
    (0.4124 * red + 0.3576 * green + 0.1805 * blue) / 0.95047,
    0.2126 * red + 0.7152 * green + 0.0722 * blue,
    (0.0193 * red + 0.1192 * green + 0.9505 * blue) / 1.08883,
  ];
}

function lab(hex: string): [number, number, number] {
  const transform = (value: number) => value > 0.008856 ? value ** (1 / 3) : 7.787 * value + 16 / 116;
  const [x, y, z] = xyz(hex).map(transform) as [number, number, number];
  return [116 * y - 16, 500 * (x - y), 200 * (y - z)];
}

function deltaE(first: string, second: string): number {
  const [l1, a1, b1] = lab(first);
  const [l2, a2, b2] = lab(second);
  return Math.hypot(l1 - l2, a1 - a2, b1 - b2);
}

function luminance(hex: string): number {
  const [red, green, blue] = rgb(hex).map(linearize) as [number, number, number];
  return 0.2126 * red + 0.7152 * green + 0.0722 * blue;
}

function contrast(first: string, second: string): number {
  const values = [luminance(first), luminance(second)].sort((left, right) => right - left);
  return (values[0] + 0.05) / (values[1] + 0.05);
}

function hsl(hex: string): [number, number, number] {
  const [red, green, blue] = rgb(hex);
  const max = Math.max(red, green, blue);
  const min = Math.min(red, green, blue);
  const lightness = (max + min) / 2;
  if (max === min) return [0, 0, lightness];

  const delta = max - min;
  const saturation = lightness > 0.5 ? delta / (2 - max - min) : delta / (max + min);
  let hue: number;
  if (max === red) hue = (green - blue) / delta + (green < blue ? 6 : 0);
  else if (max === green) hue = (blue - red) / delta + 2;
  else hue = (red - green) / delta + 4;
  return [hue * 60, saturation, lightness];
}

function everyPair<T>(items: readonly T[], assertion: (first: T, second: T) => void): void {
  for (let index = 0; index < items.length; index += 1) {
    for (const other of items.slice(index + 1)) assertion(items[index], other);
  }
}

describe("series colors", () => {
  test("classifies model vendors from names", () => {
    expect(vendorForModel("claude-opus-4-8")).toBe("anthropic");
    expect(vendorForModel("gpt-5.6-sol")).toBe("openai");
    expect(vendorForModel("gpt-6-luna")).toBe("openai");
    expect(vendorForModel("o3-mini")).toBe("openai");
    expect(vendorForModel("codex-mini")).toBe("openai");
    expect(vendorForModel("gemini-2")).toBe("other");
    expect(vendorForModel("CLAUDE-opus")).toBe("anthropic");
  });

  test("keeps each vendor family distinct, legible, and shadeable", () => {
    for (const vendor of ["anthropic", "openai", "other"] as const satisfies readonly ModelVendor[]) {
      const colors = MODEL_COLOR_FAMILIES[vendor];
      expect(colors.length).toBeGreaterThanOrEqual(5);
      expect(colors.every((color) => /^#[0-9a-f]{6}$/.test(color))).toBe(true);
      everyPair(colors, (first, second) => expect(deltaE(first, second)).toBeGreaterThanOrEqual(20));

      for (const color of colors) {
        expect(contrast(color, CHART_BACKGROUND)).toBeGreaterThanOrEqual(3);
        const lightness = hsl(color)[2] * 100;
        expect(lightness).toBeGreaterThanOrEqual(48);
        expect(lightness).toBeLessThanOrEqual(66);
        const variants = ["minimal", "low", "medium", "high", "xhigh", undefined]
          .map((effort) => effortShade(color, effort));
        everyPair(variants, (first, second) => expect(deltaE(first, second)).toBeGreaterThanOrEqual(11));
      }
    }
  });

  test("allocates distinct colors to catalog models including sol and luna", () => {
    const catalog = [
      "gpt-5.6-sol",
      "gpt-6-luna",
      "gpt-5.5",
      "claude-opus-4-8",
      "claude-sonnet-4-6",
    ];
    const colorFor = allocateModelColors(catalog);
    const colors = catalog.map(colorFor);
    expect(new Set(colors).size).toBe(catalog.length);
    expect(deltaE(colorFor("gpt-5.6-sol"), colorFor("gpt-6-luna"))).toBeGreaterThanOrEqual(20);
  });

  test("is stable for catalog order and isolated between vendors", () => {
    const catalog = ["gpt-5.6-sol", "gpt-6-luna", "claude-opus-4-8", "gemini-2"];
    const first = allocateModelColors(catalog);
    const reordered = allocateModelColors(["gemini-2", "gpt-6-luna", "gpt-5.6-sol", "claude-opus-4-8", "gpt-5.6-sol"]);
    for (const model of catalog) expect(reordered(model)).toBe(first(model));

    const withOtherVendor = allocateModelColors([...catalog, "llama-4"]);
    for (const model of ["gpt-5.6-sol", "gpt-6-luna", "claude-opus-4-8"]) {
      expect(withOtherVendor(model)).toBe(first(model));
    }
  });

  test("uses unique slots through capacity and reuses family colors after capacity", () => {
    const five = ["gpt-a", "gpt-b", "gpt-c", "gpt-d", "gpt-e"];
    const fiveColors = five.map(allocateModelColors(five));
    expect(new Set(fiveColors).size).toBe(five.length);

    const seven = [...five, "gpt-f", "gpt-g"];
    const colorFor = allocateModelColors(seven);
    for (const model of seven) expect(MODEL_COLOR_FAMILIES.openai).toContain(colorFor(model));
    expect(() => seven.map(colorFor)).not.toThrow();
  });

  test("overrides win without consuming a model family slot", () => {
    const catalog = ["gpt-5.6-sol", "gpt-6-luna", "gpt-5.5"];
    const withoutLuna = allocateModelColors(catalog.filter((model) => model !== "gpt-6-luna"));
    const withOverride = allocateModelColors(catalog, { "gpt-6-luna": "#123456" });
    expect(withOverride("gpt-6-luna")).toBe("#123456");
    for (const model of catalog.filter((value) => value !== "gpt-6-luna")) {
      expect(withOverride(model)).toBe(withoutLuna(model));
    }
  });

  test("shades efforts by ranked lightness and handles unknown values", () => {
    for (const family of Object.values(MODEL_COLOR_FAMILIES)) {
      for (const color of family) {
        expect(effortShade(color, "medium")).toBe(color);
        const ranked = ["minimal", "low", "medium", "high", "xhigh"]
          .map((effort) => hsl(effortShade(color, effort))[2]);
        expect(ranked[0]).toBeLessThan(ranked[1]);
        expect(ranked[1]).toBeLessThan(ranked[2]);
        expect(ranked[2]).toBeLessThan(ranked[3]);
        expect(ranked[3]).toBeLessThan(ranked[4]);
        expect(hsl(effortShade(color))[1]).toBeLessThan(hsl(color)[1]);
      }
    }
    expect(effortShade("#70a7e8", "turbo")).toBe(effortShade("#70a7e8", "turbo"));
  });

  test("preserves existing dark machine and subdirectory colors and namespaces", () => {
    expect(seriesColor("machine", "local")).toBe("#8fa6b5");
    expect(seriesColor("machine", "shared-name")).not.toBe(seriesColor("subdirectory", "shared-name"));
    expect(seriesColor("machine", "custom", { custom: "#123ABC" })).toBe("#123ABC");
  });
});
