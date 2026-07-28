import { describe, expect, test } from "bun:test";
import type { Resource } from "solid-js";
import type { LoadStatusResponse } from "../src/api";
import { shieldResource, shouldBlockDashboard } from "../src/dashboardLoadingState";

function status(
  phase: LoadStatusResponse["phase"],
  isLoading: boolean,
): LoadStatusResponse {
  return {
    phase,
    message: phase === "ready" ? "Usage data is ready" : "Usage data loading failed",
    completed: 1,
    total: 1,
    isLoading,
    requested: "local",
    machines: [],
  };
}

function blockInput(overrides: Partial<Parameters<typeof shouldBlockDashboard>[0]>) {
  return {
    isInitialLoading: true,
    isRangeLoading: false,
    isFetching: false,
    hasFailedRequest: false,
    ...overrides,
  };
}

describe("dashboard blocking state", () => {
  test("blocks while initial collection is still running", () => {
    expect(shouldBlockDashboard(blockInput({
      loadStatus: status("loadingWeek", true),
      isFetching: true,
    }))).toBe(true);
  });

  test("blocks while collection has not started", () => {
    expect(shouldBlockDashboard(blockInput({
      loadStatus: status("idle", false),
    }))).toBe(true);
  });

  test("blocks while load status is unknown", () => {
    expect(shouldBlockDashboard(blockInput({}))).toBe(true);
  });

  test("keeps blocking through a warm start: ready but first requests still in flight", () => {
    expect(shouldBlockDashboard(blockInput({
      loadStatus: status("ready", false),
      isFetching: true,
    }))).toBe(true);
  });

  test("does not remain blocked when collection is ready and requests have settled without data", () => {
    expect(shouldBlockDashboard(blockInput({
      loadStatus: status("ready", false),
      hasFailedRequest: true,
    }))).toBe(false);
  });

  test("does not re-block while a failed request is being retried", () => {
    expect(shouldBlockDashboard(blockInput({
      loadStatus: status("ready", false),
      isFetching: true,
      hasFailedRequest: true,
    }))).toBe(false);
  });

  test("does not remain blocked after collection fails", () => {
    expect(shouldBlockDashboard(blockInput({
      loadStatus: status("failed", false),
      hasFailedRequest: true,
    }))).toBe(false);
  });

  test("does not block once initial data is present", () => {
    expect(shouldBlockDashboard(blockInput({
      isInitialLoading: false,
      loadStatus: status("ready", false),
    }))).toBe(false);
  });

  test("keeps an explicitly requested range transition blocking", () => {
    expect(shouldBlockDashboard(blockInput({
      isInitialLoading: false,
      isRangeLoading: true,
      loadStatus: status("ready", false),
    }))).toBe(true);
  });
});

function fakeResource<T>(input: { value?: T; error?: unknown; loading?: boolean }): Resource<T> {
  const read = () => {
    if (input.error != null) throw input.error;
    return input.value;
  };
  Object.defineProperties(read, {
    state: { get: () => (input.error != null ? "errored" : "ready") },
    error: { get: () => input.error },
    loading: { get: () => input.loading ?? false },
    latest: { get: read },
  });
  return read as Resource<T>;
}

describe("shieldResource", () => {
  test("passes through resolved values and loading state", () => {
    const shielded = shieldResource(fakeResource({ value: 42, loading: true }));
    expect(shielded()).toBe(42);
    expect(shielded.latest).toBe(42);
    expect(shielded.loading).toBe(true);
    expect(shielded.error).toBeUndefined();
  });

  test("reads as undefined instead of throwing while errored", () => {
    const failure = new Error("boom");
    const shielded = shieldResource(fakeResource<number>({ error: failure }));
    expect(shielded()).toBeUndefined();
    expect(shielded.latest).toBeUndefined();
    expect(shielded.error).toBe(failure);
    expect(shielded.state).toBe("errored");
  });
});
