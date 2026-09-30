import type { ColorScheme } from "./colorScheme";
import { EFFORT_ORDER, effortRank } from "./effort";

export type ModelVendor = "anthropic" | "openai" | "other";

export function vendorForModel(model: string): ModelVendor {
  const normalized = model.toLowerCase();
  if (normalized.includes("claude")) return "anthropic";
  if (normalized.startsWith("gpt-") || normalized.startsWith("codex") || /^o\d/.test(normalized)) {
    return "openai";
  }
  return "other";
}

// Nine colors chosen together so every pair is >= 19 CIEDE2000 apart in both themes; vendor hue
// families (Anthropic warm, OpenAI cyan/blue/green, other magenta/rose/violet) are a preference only.
export const MODEL_COLOR_FAMILIES: Readonly<Record<ModelVendor, readonly string[]>> = {
  anthropic: ["#ff4754", "#ffae51", "#fff129"],
  openai: ["#2fc3da", "#2f7fda", "#63dc38"],
  other: ["#f651ff", "#be3774", "#6949df"],
};

// Same hue and saturation per slot as the dark families, with lightness chosen for >=3:1 on a white chart.
export const LIGHT_MODEL_COLOR_FAMILIES: Readonly<Record<ModelVendor, readonly string[]>> = {
  anthropic: ["#b8000c", "#e07800", "#857c00"],
  openai: ["#20a2b6", "#1f61ad", "#3a931a"],
  other: ["#e900f5", "#8e2957", "#4723c7"],
};

const MODEL_VENDORS = ["anthropic", "openai", "other"] as const satisfies readonly ModelVendor[];

export function modelColorFamilies(scheme: ColorScheme = "dark"): Readonly<Record<ModelVendor, readonly string[]>> {
  return scheme === "light" ? LIGHT_MODEL_COLOR_FAMILIES : MODEL_COLOR_FAMILIES;
}

export type SeriesKind = "machine" | "subdirectory";

export const CHART_BACKGROUND = "#15171c";
export const LIGHT_CHART_BACKGROUND = "#ffffff";

const darkSeriesColors: Record<SeriesKind, readonly string[]> = {
  machine: ["#55c98a", "#70a7e8", "#e6a15c", "#a98ae8", "#e77b9d", "#70c7c1", "#c2ae57", "#8fa6b5"],
  subdirectory: ["#a98ae8", "#55c98a", "#e6a15c", "#70a7e8", "#e77b9d", "#70c7c1", "#c2ae57", "#8fa6b5"],
};

const lightSeriesColors: Record<SeriesKind, readonly string[]> = {
  machine: ["#33a266", "#3583de", "#d27920", "#7c4cdc", "#dc3f71", "#3fa09a", "#a5913c", "#68879b"],
  subdirectory: ["#7c4cdc", "#33a266", "#d27920", "#3583de", "#dc3f71", "#3fa09a", "#a5913c", "#68879b"],
};

function stableHash(value: string) {
  let hash = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return hash >>> 0;
}

function preferredSlot(model: string, size: number): number {
  return stableHash(`model:${model}`) % size;
}

// Allocation is stable for a fixed model catalog; contested colors can shift when it changes.
// Each vendor fills its own family first; extra models borrow unused colors from other families,
// so no two models share a color until all nine are in use.
export function allocateModelColors(
  catalog: readonly string[],
  overrides?: Readonly<Record<string, string>>,
  scheme: ColorScheme = "dark",
): (model: string) => string {
  const families = modelColorFamilies(scheme);
  const palette = MODEL_VENDORS.flatMap((vendor) => families[vendor]);
  const modelsByVendor: Record<ModelVendor, string[]> = {
    anthropic: [],
    openai: [],
    other: [],
  };
  for (const model of [...new Set(catalog)].sort()) {
    if (typeof overrides?.[model] === "string") continue;
    modelsByVendor[vendorForModel(model)].push(model);
  }

  const allocated = new Map<string, string>();
  const usedColors = new Set<string>();
  const overflow: string[] = [];
  for (const vendor of MODEL_VENDORS) {
    const family = families[vendor];
    const used = new Set<number>();
    for (const model of modelsByVendor[vendor]) {
      if (used.size === family.length) {
        overflow.push(model);
        continue;
      }
      let slot = preferredSlot(model, family.length);
      while (used.has(slot)) slot = (slot + 1) % family.length;
      used.add(slot);
      allocated.set(model, family[slot]);
      usedColors.add(family[slot]);
    }
  }

  for (const model of overflow.sort()) {
    if (usedColors.size === palette.length) usedColors.clear();
    let index = preferredSlot(model, palette.length);
    while (usedColors.has(palette[index])) index = (index + 1) % palette.length;
    usedColors.add(palette[index]);
    allocated.set(model, palette[index]);
  }

  return (model: string): string => {
    const override = overrides?.[model];
    if (typeof override === "string") return override;
    const color = allocated.get(model);
    if (color !== undefined) return color;
    const family = families[vendorForModel(model)];
    return family[preferredSlot(model, family.length)];
  };
}

function toHsl(color: string): [number, number, number] {
  const red = Number.parseInt(color.slice(1, 3), 16) / 255;
  const green = Number.parseInt(color.slice(3, 5), 16) / 255;
  const blue = Number.parseInt(color.slice(5, 7), 16) / 255;
  const max = Math.max(red, green, blue);
  const min = Math.min(red, green, blue);
  const lightness = (max + min) / 2;

  if (max === min) return [0, 0, lightness];

  const delta = max - min;
  const saturation = lightness > 0.5
    ? delta / (2 - max - min)
    : delta / (max + min);
  let hue: number;
  if (max === red) hue = (green - blue) / delta + (green < blue ? 6 : 0);
  else if (max === green) hue = (blue - red) / delta + 2;
  else hue = (red - green) / delta + 4;
  return [hue * 60, saturation, lightness];
}

function fromHsl(hue: number, saturation: number, lightness: number): string {
  const chroma = (1 - Math.abs(2 * lightness - 1)) * saturation;
  const hueSector = hue / 60;
  const secondary = chroma * (1 - Math.abs((hueSector % 2) - 1));
  const [red, green, blue] = hueSector < 1
    ? [chroma, secondary, 0]
    : hueSector < 2
      ? [secondary, chroma, 0]
      : hueSector < 3
        ? [0, chroma, secondary]
        : hueSector < 4
          ? [0, secondary, chroma]
          : hueSector < 5
            ? [secondary, 0, chroma]
            : [chroma, 0, secondary];
  const match = lightness - chroma / 2;
  return `#${[red, green, blue]
    .map((channel) => Math.round((channel + match) * 255).toString(16).padStart(2, "0"))
    .join("")}`;
}

interface EffortLadder {
  ranked: Readonly<Record<string, number>>;
  unranked: readonly number[];
  minLightness: number;
  maxLightness: number;
}

const effortLadders: Readonly<Record<ColorScheme, EffortLadder>> = {
  dark: {
    ranked: { minimal: -30, low: -16, medium: 0, high: 16, xhigh: 28 },
    unranked: [-23, -8, 8, 23],
    minLightness: 20,
    maxLightness: 90,
  },
  // Light bases sit lower in lightness, so the ladder reaches further up than down.
  light: {
    ranked: { minimal: -18, low: -9, medium: 0, high: 17, xhigh: 32 },
    unranked: [-13, -4, 8, 24],
    minLightness: 8,
    maxLightness: 94,
  },
};

export function effortShade(baseColor: string, effort?: string, scheme: ColorScheme = "dark"): string {
  const [hue, saturation, lightness] = toHsl(baseColor);
  if (effort === undefined || effort === "") {
    return fromHsl(hue, saturation * 0.35, lightness);
  }

  const ladder = effortLadders[scheme];
  const offset = effortRank(effort) < EFFORT_ORDER.length
    ? ladder.ranked[effort]
    : ladder.unranked[stableHash(`effort:${effort}`) % ladder.unranked.length];
  const shadedLightness = Math.max(ladder.minLightness, Math.min(ladder.maxLightness, lightness * 100 + offset)) / 100;
  return fromHsl(hue, saturation, shadedLightness);
}

export function seriesColor(
  kind: SeriesKind,
  key: string,
  overrides?: Readonly<Record<string, string>>,
  scheme: ColorScheme = "dark",
): string {
  const override = overrides?.[key];
  if (typeof override === "string") return override;
  const colors = (scheme === "light" ? lightSeriesColors : darkSeriesColors)[kind];
  return colors[stableHash(`${kind}:${key}`) % colors.length];
}
