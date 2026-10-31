const storageKey = "ccusage-gauge-collapsed-sections";
type SectionStorage = Pick<Storage, "getItem" | "setItem">;

function defaultStorage(): SectionStorage | undefined {
  try { return globalThis.localStorage; } catch { return undefined; }
}

export function readCollapsedSections(storage: SectionStorage | undefined = defaultStorage()): string[] {
  try {
    const value: unknown = JSON.parse(storage?.getItem(storageKey) ?? "[]");
    return Array.isArray(value) ? [...new Set(value.filter((id): id is string => typeof id === "string"))] : [];
  } catch { return []; }
}

export function storeSectionCollapsed(id: string, collapsed: boolean, storage: SectionStorage | undefined = defaultStorage()): void {
  const next = new Set(readCollapsedSections(storage));
  if (collapsed) next.add(id); else next.delete(id);
  try { storage?.setItem(storageKey, JSON.stringify([...next])); } catch { /* Keep working when local storage is unavailable. */ }
}
