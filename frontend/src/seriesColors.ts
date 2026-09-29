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

export const MODEL_COLOR_FAMILIES: Readonly<Record<ModelVendor, readonly string[]>> = {
  anthropic: ["#d78c57", "#fb0906", "#fad20b", "#c83837", "#fb7b09"],
  openai: ["#55bdcf", "#154ffa", "#09fb5e", "#2f70c7", "#17f9c2"],
  other: ["#cd67d7", "#8d07fb", "#f6047d", "#fa14ee", "#7a47df"],
};

export type SeriesKind = "machine" | "subdirectory";

export const CHART_BACKGROUND = "#15171c";

const darkSeriesColors: Record<SeriesKind, readonly string[]> = {
  machine: ["#55c98a", "#70a7e8", "#e6a15c", "#a98ae8", "#e77b9d", "#70c7c1", "#c2ae57", "#8fa6b5"],
  subdirectory: ["#a98ae8", "#55c98a", "#e6a15c", "#70a7e8", "#e77b9d", "#70c7c1", "#c2ae57", "#8fa6b5"],
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
export function allocateModelColors(
  catalog: readonly string[],
  overrides?: Readonly<Record<string, string>>,
): (model: string) => string {
  const modelsByVendor: Record<ModelVendor, string[]> = {
    anthropic: [],
    openai: [],
    other: [],
  };
  for (const model of [...new Set(catalog)].sort()) {
    modelsByVendor[vendorForModel(model)].push(model);
  }

  const allocated = new Map<string, string>();
  for (const vendor of ["anthropic", "openai", "other"] as const) {
    const family = MODEL_COLOR_FAMILIES[vendor];
    const used = new Set<number>();
    for (const model of modelsByVendor[vendor]) {
      if (typeof overrides?.[model] === "string") continue;
      if (used.size === family.length) used.clear();

      const preferred = preferredSlot(model, family.length);
      let slot = preferred;
      while (used.has(slot)) slot = (slot + 1) % family.length;
      used.add(slot);
      allocated.set(model, family[slot]);
    }
  }

  return (model: string): string => {
    const override = overrides?.[model];
    if (typeof override === "string") return override;
    const color = allocated.get(model);
    if (color !== undefined) return color;
    const family = MODEL_COLOR_FAMILIES[vendorForModel(model)];
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

export function effortShade(baseColor: string, effort?: string): string {
  const [hue, saturation, lightness] = toHsl(baseColor);
  if (effort === undefined || effort === "") {
    return fromHsl(hue, saturation * 0.35, lightness);
  }

  const rank = effortRank(effort);
  const rankedOffsets: Readonly<Record<string, number>> = {
    minimal: -30,
    low: -16,
    medium: 0,
    high: 16,
    xhigh: 28,
  };
  const offset = rank < EFFORT_ORDER.length
    ? rankedOffsets[effort]
    : [-23, -8, 8, 23][stableHash(`effort:${effort}`) % 4];
  const shadedLightness = Math.max(20, Math.min(90, lightness * 100 + offset)) / 100;
  return fromHsl(hue, saturation, shadedLightness);
}

export function seriesColor(
  kind: SeriesKind,
  key: string,
  overrides?: Readonly<Record<string, string>>,
): string {
  const override = overrides?.[key];
  if (typeof override === "string") return override;
  const colors = darkSeriesColors[kind];
  return colors[stableHash(`${kind}:${key}`) % colors.length];
}
