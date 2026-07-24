import { afterEach, describe, expect, test } from "bun:test";
import { DashboardRequestTimeoutError, requestJSON } from "../src/api";

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
});
