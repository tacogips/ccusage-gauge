export type ColorScheme = "dark" | "light";

export const DEFAULT_COLOR_SCHEME: ColorScheme = "dark";
// A new key on purpose: the pre-dark-only key was written from prefers-color-scheme,
// so reading it would reopen light-OS users in light instead of the dark default.
export const COLOR_SCHEME_STORAGE_KEY = "ccusage-gauge-theme";

type SchemeStorage = Pick<Storage, "getItem" | "setItem">;

function defaultStorage(): SchemeStorage | undefined {
  try {
    return globalThis.localStorage;
  } catch {
    return undefined;
  }
}

export function parseColorScheme(value: unknown): ColorScheme {
  return value === "light" ? "light" : DEFAULT_COLOR_SCHEME;
}

export function readStoredColorScheme(storage: SchemeStorage | undefined = defaultStorage()): ColorScheme {
  try {
    return parseColorScheme(storage?.getItem(COLOR_SCHEME_STORAGE_KEY));
  } catch {
    return DEFAULT_COLOR_SCHEME;
  }
}

export function storeColorScheme(scheme: ColorScheme, storage: SchemeStorage | undefined = defaultStorage()): void {
  try {
    storage?.setItem(COLOR_SCHEME_STORAGE_KEY, scheme);
  } catch {
    // Storage can be unavailable (private window, blocked site data); the theme still applies for this session.
  }
}

export function applyColorScheme(root: Pick<HTMLElement, "dataset">, scheme: ColorScheme): void {
  root.dataset.theme = scheme;
}

export function oppositeColorScheme(scheme: ColorScheme): ColorScheme {
  return scheme === "dark" ? "light" : "dark";
}
