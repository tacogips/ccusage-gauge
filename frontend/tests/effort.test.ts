import { describe, expect, test } from "bun:test";
import { effortLabel, effortRank } from "../src/effort";

describe("effort helpers", () => {
  test("orders known efforts before unknown and missing values", () => {
    expect(
      effortRank("minimal") < effortRank("low")
        && effortRank("low") < effortRank("medium")
        && effortRank("medium") < effortRank("high")
        && effortRank("high") < effortRank("xhigh")
        && effortRank("xhigh") < effortRank("turbo")
        && effortRank("turbo") < effortRank(undefined),
    ).toBe(true);
  });

  test("labels missing and empty effort as unknown", () => {
    expect(effortLabel(undefined)).toBe("unknown");
    expect(effortLabel("")).toBe("unknown");
    expect(effortLabel("high")).toBe("high");
  });
});
