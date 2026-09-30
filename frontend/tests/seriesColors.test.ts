import { describe, expect, test } from "bun:test";
import {
  allocateModelColors,
  CHART_BACKGROUND,
  effortShade,
  LIGHT_CHART_BACKGROUND,
  LIGHT_MODEL_COLOR_FAMILIES,
  MODEL_COLOR_FAMILIES,
  modelColorFamilies,
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

// CIEDE2000; CIE76 overstates blue differences, so perceptual distinctness is asserted with this.
function deltaE2000(first: string, second: string): number {
  const [l1, a1, b1] = lab(first);
  const [l2, a2, b2] = lab(second);
  const radians = (degrees: number) => (degrees * Math.PI) / 180;
  const chromaMean = (Math.hypot(a1, b1) + Math.hypot(a2, b2)) / 2;
  const g = 0.5 * (1 - Math.sqrt(chromaMean ** 7 / (chromaMean ** 7 + 25 ** 7)));
  const a1p = (1 + g) * a1;
  const a2p = (1 + g) * a2;
  const c1p = Math.hypot(a1p, b1);
  const c2p = Math.hypot(a2p, b2);
  const hue = (b: number, a: number) => ((Math.atan2(b, a) * 180) / Math.PI + 360) % 360;
  const h1p = hue(b1, a1p);
  const h2p = hue(b2, a2p);
  let deltaHue = h2p - h1p;
  if (c1p * c2p === 0) deltaHue = 0;
  else if (deltaHue > 180) deltaHue -= 360;
  else if (deltaHue < -180) deltaHue += 360;
  const deltaL = l2 - l1;
  const deltaC = c2p - c1p;
  const deltaH = 2 * Math.sqrt(c1p * c2p) * Math.sin(radians(deltaHue / 2));
  const lMean = (l1 + l2) / 2;
  const cMean = (c1p + c2p) / 2;
  const hMean = Math.abs(h1p - h2p) <= 180
    ? (h1p + h2p) / 2
    : h1p + h2p < 360 ? (h1p + h2p + 360) / 2 : (h1p + h2p - 360) / 2;
  const t = 1 - 0.17 * Math.cos(radians(hMean - 30)) + 0.24 * Math.cos(radians(2 * hMean))
    + 0.32 * Math.cos(radians(3 * hMean + 6)) - 0.2 * Math.cos(radians(4 * hMean - 63));
  const sl = 1 + (0.015 * (lMean - 50) ** 2) / Math.sqrt(20 + (lMean - 50) ** 2);
  const sc = 1 + 0.045 * cMean;
  const sh = 1 + 0.015 * cMean * t;
  const rotation = 30 * Math.exp(-(((hMean - 275) / 25) ** 2));
  const rt = -Math.sin(radians(2 * rotation)) * 2 * Math.sqrt(cMean ** 7 / (cMean ** 7 + 25 ** 7));
  return Math.sqrt((deltaL / sl) ** 2 + (deltaC / sc) ** 2 + (deltaH / sh) ** 2 + rt * (deltaC / sc) * (deltaH / sh));
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

  test("keeps all nine model colors perceptually distinct in both themes", () => {
    for (const families of [MODEL_COLOR_FAMILIES, LIGHT_MODEL_COLOR_FAMILIES]) {
      const palette = Object.values(families).flat();
      expect(palette.length).toBe(9);
      expect(new Set(palette).size).toBe(9);
      everyPair(palette, (first, second) => expect(deltaE2000(first, second)).toBeGreaterThanOrEqual(19));
    }
  });

  test("keeps each dark vendor family legible and shadeable", () => {
    for (const vendor of ["anthropic", "openai", "other"] as const satisfies readonly ModelVendor[]) {
      const colors = MODEL_COLOR_FAMILIES[vendor];
      expect(colors.length).toBe(3);
      expect(colors.every((color) => /^#[0-9a-f]{6}$/.test(color))).toBe(true);
      everyPair(colors, (first, second) => expect(deltaE2000(first, second)).toBeGreaterThanOrEqual(24));

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
    expect(deltaE2000(colorFor("gpt-5.6-sol"), colorFor("gpt-6-luna"))).toBeGreaterThanOrEqual(19);
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

  test("fills the vendor family first, then borrows unused colors, then reuses", () => {
    const three = ["gpt-6-luna", "gpt-6-sol", "gpt-6.1-sol"];
    const threeColors = three.map(allocateModelColors(three));
    expect(new Set(threeColors).size).toBe(3);
    for (const color of threeColors) expect(MODEL_COLOR_FAMILIES.openai).toContain(color);

    const mixed = [...three, "gpt-5.5", "gpt-5", "claude-opus-5-5", "claude-sonnet-5-5"];
    const mixedColors = mixed.map(allocateModelColors(mixed));
    expect(new Set(mixedColors).size).toBe(mixed.length);
    everyPair(mixedColors, (first, second) => expect(deltaE2000(first, second)).toBeGreaterThanOrEqual(19));

    const nine = Array.from({ length: 9 }, (_, index) => `gpt-${index}`);
    expect(new Set(nine.map(allocateModelColors(nine))).size).toBe(9);

    const eleven = [...nine, "gpt-9", "gpt-10"];
    const colorFor = allocateModelColors(eleven);
    const palette = Object.values(MODEL_COLOR_FAMILIES).flat();
    for (const model of eleven) expect(palette).toContain(colorFor(model));
    expect(new Set(eleven.map(colorFor)).size).toBe(9);
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

describe("light series colors", () => {
  const catalog = ["gpt-5.6-sol", "gpt-6-luna", "claude-opus-4-8", "gemini-2"];

  test("selects the light palette while keeping dark as the default", () => {
    expect(LIGHT_CHART_BACKGROUND).toBe("#ffffff");
    expect(modelColorFamilies("light")).toBe(LIGHT_MODEL_COLOR_FAMILIES);
    expect(modelColorFamilies()).toBe(MODEL_COLOR_FAMILIES);
  });

  test("keeps each vendor light family legible and distinct", () => {
    for (const vendor of ["anthropic", "openai", "other"] as const satisfies readonly ModelVendor[]) {
      const colors = LIGHT_MODEL_COLOR_FAMILIES[vendor];
      expect(colors.length).toBe(MODEL_COLOR_FAMILIES[vendor].length);
      expect(colors.every((color) => /^#[0-9a-f]{6}$/.test(color))).toBe(true);
      for (const color of colors) expect(contrast(color, LIGHT_CHART_BACKGROUND)).toBeGreaterThanOrEqual(3);
      everyPair(colors, (first, second) => expect(deltaE2000(first, second)).toBeGreaterThanOrEqual(24));
    }
  });

  test("keeps light palette hues within five degrees of matching dark slots", () => {
    for (const [vendor, lightColors] of Object.entries(LIGHT_MODEL_COLOR_FAMILIES) as [ModelVendor, readonly string[]][]) {
      const darkColors = MODEL_COLOR_FAMILIES[vendor];
      for (const [index, lightColor] of lightColors.entries()) {
        const distance = Math.abs(hsl(lightColor)[0] - hsl(darkColors[index])[0]);
        expect(Math.min(distance, 360 - distance)).toBeLessThanOrEqual(5);
      }
    }
  });

  test("keeps machine and subdirectory light colors distinct and legible", () => {
    for (const kind of ["machine", "subdirectory"] as const) {
      const colors = new Set(Array.from({ length: 300 }, (_, index) => seriesColor(kind, `key-${index}`, undefined, "light")));
      expect(colors.size).toBe(8);
      for (const color of colors) expect(contrast(color, "#ffffff")).toBeGreaterThanOrEqual(3);
    }
  });

  test("orders light effort shades, separates them, and desaturates missing effort", () => {
    for (const family of Object.values(LIGHT_MODEL_COLOR_FAMILIES)) {
      for (const color of family) {
        const ranked = ["minimal", "low", "medium", "high", "xhigh"]
          .map((effort) => effortShade(color, effort, "light"));
        for (let index = 1; index < ranked.length; index += 1) {
          expect(hsl(ranked[index - 1])[2]).toBeLessThan(hsl(ranked[index])[2]);
        }
        everyPair(ranked, (first, second) => expect(deltaE(first, second)).toBeGreaterThanOrEqual(11));
        expect(hsl(effortShade(color, undefined, "light"))[1]).toBeLessThan(hsl(color)[1]);
        const unknown = effortShade(color, "turbo", "light");
        expect(unknown).toMatch(/^#[0-9a-f]{6}$/);
        expect(unknown).toBe(effortShade(color, "turbo", "light"));
      }
    }
  });

  test("keeps dark defaults identical to explicit dark behavior", () => {
    for (const color of Object.values(MODEL_COLOR_FAMILIES).flat()) {
      expect(effortShade(color, "high")).toBe(effortShade(color, "high", "dark"));
    }
    const defaultColors = allocateModelColors(catalog);
    const darkColors = allocateModelColors(catalog, undefined, "dark");
    for (const model of catalog) expect(defaultColors(model)).toBe(darkColors(model));
    expect(seriesColor("machine", "local")).toBe(seriesColor("machine", "local", undefined, "dark"));
  });

  test("preserves matching model slots between themes", () => {
    const lightColors = allocateModelColors(catalog, undefined, "light");
    const darkColors = allocateModelColors(catalog, undefined, "dark");
    const lightPalette = Object.values(LIGHT_MODEL_COLOR_FAMILIES).flat();
    const darkPalette = Object.values(MODEL_COLOR_FAMILIES).flat();
    for (const model of [...catalog, "gpt-a", "gpt-b", "gpt-c"]) {
      const light = allocateModelColors([...catalog, "gpt-a", "gpt-b", "gpt-c"], undefined, "light")(model);
      const dark = allocateModelColors([...catalog, "gpt-a", "gpt-b", "gpt-c"], undefined, "dark")(model);
      expect(lightPalette.indexOf(light)).toBe(darkPalette.indexOf(dark));
    }
    for (const model of catalog) expect(lightPalette.indexOf(lightColors(model))).toBe(darkPalette.indexOf(darkColors(model)));
  });

  test("uses model and machine overrides in light", () => {
    expect(allocateModelColors(catalog, { "gpt-6-luna": "#123456" }, "light")("gpt-6-luna")).toBe("#123456");
    expect(seriesColor("machine", "custom", { custom: "#123ABC" }, "light")).toBe("#123ABC");
  });
});
