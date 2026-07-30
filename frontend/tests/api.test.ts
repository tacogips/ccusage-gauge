import { afterEach, describe, expect, test } from "bun:test";
import {
  DashboardRequestTimeoutError,
  renameSubdirectory,
  requestJSON,
  type CostRow,
  type MachinesResponse,
  type MetricRow,
  type SubdirectoriesResponse,
} from "../src/api";

const originalFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = originalFetch;
});

describe("dashboard API requests", () => {
  test("aborts a stalled request at the configured deadline", async () => {
    globalThis.fetch = ((_: RequestInfo | URL, init?: RequestInit) => new Promise<Response>((_, reject) => {
      init?.signal?.addEventListener("abort", () => reject(init.signal?.reason ?? new DOMException("Aborted", "AbortError")));
    })) as typeof fetch;

    const request = requestJSON("/api/refresh", {}, 5);

    await expect(request).rejects.toBeInstanceOf(DashboardRequestTimeoutError);
    await expect(request).rejects.toThrow("timed out after 1 seconds");
  });

  test("preserves caller cancellation instead of reporting a timeout", async () => {
    globalThis.fetch = ((_: RequestInfo | URL, init?: RequestInit) => new Promise<Response>((_, reject) => {
      init?.signal?.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")));
    })) as typeof fetch;
    const controller = new AbortController();
    const request = requestJSON("/api/metrics", { signal: controller.signal }, 1_000);

    controller.abort();

    await expect(request).rejects.toMatchObject({ name: "AbortError" });
  });

  test("keeps directory fields optional for old metric and cost payloads", () => {
    const metric = {
      date: "2026-07-16", agent: "codex", model: "gpt", costUSD: 1,
      inputTokens: 1, outputTokens: 2, cacheCreationTokens: 0,
      cacheReadTokens: 3, totalTokens: 6, machine: "local",
    } satisfies MetricRow;
    const cost = {
      timestamp: "2026-07-16T00:00:00Z", agent: "codex", model: "gpt", costUSD: 1,
      inputTokens: 1, outputTokens: 2, cacheCreationTokens: 0,
      cacheReadTokens: 3, totalTokens: 6, machine: "local", dataQuality: "timestamped",
    } satisfies CostRow;

    expect(metric).not.toHaveProperty("directory");
    expect(cost).not.toHaveProperty("directory");
  });

  test("keeps names optional for old subdirectory payloads", () => {
    const payload = {
      machines: [{ machine: "local", directories: ["/work/project"] }],
    } satisfies SubdirectoriesResponse;

    expect(payload.machines[0]).not.toHaveProperty("names");
  });

  test("keeps metadata cleanup diagnostics optional for old machine payloads", () => {
    const payload = { machines: [] } satisfies MachinesResponse;

    expect(payload).not.toHaveProperty("metadataCleanupPendingMachineIds");
  });

  test("sends the guarded rename request and supports null clear", async () => {
    const calls: Array<{ path: string; init?: RequestInit }> = [];
    globalThis.fetch = (async (path: RequestInfo | URL, init?: RequestInit) => {
      calls.push({ path: String(path), init });
      return new Response(JSON.stringify({
        status: "ok",
        machine: "local",
        directory: "/work/project",
        name: null,
      }), { status: 200, headers: { "Content-Type": "application/json" } });
    }) as typeof fetch;

    await renameSubdirectory({
      machine: "local",
      directory: "/work/project",
      name: null,
    });

    expect(calls).toHaveLength(1);
    expect(calls[0].path).toBe("/api/subdirectories/name");
    expect(calls[0].init?.method).toBe("PUT");
    expect(new Headers(calls[0].init?.headers).get("X-CCUsage-Gauge-Mutation")).toBe("1");
    expect(new Headers(calls[0].init?.headers).get("Content-Type")).toBe("application/json");
    expect(JSON.parse(String(calls[0].init?.body))).toEqual({
      machine: "local",
      directory: "/work/project",
      name: null,
    });
  });
});
