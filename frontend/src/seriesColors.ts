export type SeriesKind = "machine" | "model";
export type ColorScheme = "light" | "dark";

const colorsByScheme: Record<ColorScheme, Record<SeriesKind, readonly string[]>> = {
  light: {
    machine: ["#238855", "#3f75b5", "#b86f32", "#7b5eb5", "#b84f6f", "#468a86", "#8a7a35", "#596d7a"],
    model: ["#3f75b5", "#238855", "#7b5eb5", "#b86f32", "#468a86", "#b84f6f", "#596d7a", "#8a7a35"],
  },
  dark: {
    machine: ["#55c98a", "#70a7e8", "#e6a15c", "#a98ae8", "#e77b9d", "#70c7c1", "#c2ae57", "#8fa6b5"],
    model: ["#70a7e8", "#55c98a", "#a98ae8", "#e6a15c", "#70c7c1", "#e77b9d", "#8fa6b5", "#c2ae57"],
  },
};

function stableHash(value: string) {
  let hash = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return hash >>> 0;
}

export function seriesColor(scheme: ColorScheme, kind: SeriesKind, key: string, overrides?: Readonly<Record<string, string>>) {
  const override = overrides?.[key];
  if (typeof override === "string") return override;
  const colors = colorsByScheme[scheme][kind];
  return colors[stableHash(`${kind}:${key}`) % colors.length];
}
