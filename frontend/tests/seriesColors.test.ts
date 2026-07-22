import { describe, expect, test } from "bun:test";
import { seriesColor } from "../src/seriesColors";

describe("series colors", () => {
  test("assigns fixed colors from machine identity", () => {
    expect(seriesColor("light", "machine", "local")).toBe("#596d7a");
    expect(seriesColor("light", "machine", "build-host")).toBe("#468a86");
  });

  test("assigns fixed colors from model identity", () => {
    expect(seriesColor("light", "model", "claude-opus-4-8")).toBe("#596d7a");
    expect(seriesColor("light", "model", "gpt-5.6-sol")).toBe("#3f75b5");
  });

  test("uses separate stable namespaces for machines and models", () => {
    expect(seriesColor("light", "machine", "shared-name")).toBe("#596d7a");
    expect(seriesColor("light", "model", "shared-name")).toBe("#b86f32");
  });

  test("switches fallback palettes between light and dark schemes", () => {
    expect(seriesColor("light", "machine", "local")).toBe("#596d7a");
    expect(seriesColor("dark", "machine", "local")).toBe("#8fa6b5");
    expect(seriesColor("light", "model", "gpt-5.6-sol")).toBe("#3f75b5");
    expect(seriesColor("dark", "model", "gpt-5.6-sol")).toBe("#70a7e8");
  });

  test("uses scheme-specific overrides without affecting unknown future identities", () => {
    const overrides = { "gpt-custom": "#123ABC" };

    expect(seriesColor("dark", "model", "gpt-custom", overrides)).toBe("#123ABC");
    expect(seriesColor("dark", "model", "future-model", overrides)).toBe(seriesColor("dark", "model", "future-model"));
  });
});
