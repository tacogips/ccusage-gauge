import { describe, expect, test } from "bun:test";
import {
  applyColorScheme,
  COLOR_SCHEME_STORAGE_KEY,
  DEFAULT_COLOR_SCHEME,
  oppositeColorScheme,
  parseColorScheme,
  readStoredColorScheme,
  storeColorScheme,
} from "../src/colorScheme";

function memoryStorage(initial: Record<string, string> = {}) {
  const values = new Map(Object.entries(initial));
  return {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => void values.set(key, value),
    values,
  };
}

const throwingStorage = {
  getItem: (): string | null => { throw new Error("blocked"); },
  setItem: (): void => { throw new Error("blocked"); },
};

describe("color scheme preference", () => {
  test("defaults to dark and accepts only an explicit light choice", () => {
    expect(DEFAULT_COLOR_SCHEME).toBe("dark");
    expect(parseColorScheme(null)).toBe("dark");
    expect(parseColorScheme("")).toBe("dark");
    expect(parseColorScheme("system")).toBe("dark");
    expect(parseColorScheme("light")).toBe("light");
  });

  test("ignores the legacy auto-written scheme key", () => {
    expect(COLOR_SCHEME_STORAGE_KEY).not.toBe("ccusage-gauge-color-scheme");
    expect(readStoredColorScheme(memoryStorage({ "ccusage-gauge-color-scheme": "light" }))).toBe("dark");
  });

  test("round-trips the stored choice", () => {
    const storage = memoryStorage();
    expect(readStoredColorScheme(storage)).toBe("dark");
    storeColorScheme("light", storage);
    expect(storage.values.get(COLOR_SCHEME_STORAGE_KEY)).toBe("light");
    expect(readStoredColorScheme(storage)).toBe("light");
  });

  test("falls back to dark when storage is missing or throws", () => {
    expect(readStoredColorScheme(undefined)).toBe("dark");
    expect(readStoredColorScheme(throwingStorage)).toBe("dark");
    expect(() => storeColorScheme("light", throwingStorage)).not.toThrow();
  });

  test("applies the scheme to the root dataset and toggles", () => {
    const root = { dataset: {} as DOMStringMap };
    applyColorScheme(root, "light");
    expect(root.dataset.theme).toBe("light");
    expect(oppositeColorScheme("dark")).toBe("light");
    expect(oppositeColorScheme("light")).toBe("dark");
  });
});
