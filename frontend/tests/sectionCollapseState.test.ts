import { describe, expect, test } from "bun:test";
import { readCollapsedSections, storeSectionCollapsed } from "../src/sectionCollapseState";

function storage(initial = "[]") {
  let value = initial;
  return { getItem: () => value, setItem: (_key: string, next: string) => { value = next; } };
}

describe("section collapse preferences", () => {
  test("preserves independent folds across a reload and removes expanded sections", () => {
    const saved = storage();
    storeSectionCollapsed("subscription-usage", true, saved);
    storeSectionCollapsed("metric-cost", true, saved);
    expect(readCollapsedSections(saved)).toEqual(["subscription-usage", "metric-cost"]);
    storeSectionCollapsed("metric-cost", false, saved);
    expect(readCollapsedSections(saved)).toEqual(["subscription-usage"]);
  });
  test("recovers from corrupt, denied, or legacy storage", () => {
    expect(readCollapsedSections(storage("broken"))).toEqual([]);
    expect(readCollapsedSections(storage("{}"))).toEqual([]);
    expect(readCollapsedSections(storage('["cost",3,"cost"]'))).toEqual(["cost"]);
    const denied = { getItem: () => { throw Error("blocked"); }, setItem: () => { throw Error("blocked"); } };
    expect(readCollapsedSections(denied)).toEqual([]);
    expect(() => storeSectionCollapsed("cost", true, denied)).not.toThrow();
  });
});
