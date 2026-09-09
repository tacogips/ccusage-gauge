import { expect, test } from "bun:test";
import type { invoke } from "@tauri-apps/api/core";
import { desktopFetch } from "../src/desktopTransport";

test("native transport forwards JSON mutations and preserves API errors", async () => {
  const calls: unknown[] = [];
  const call = (async (command: string, args: unknown) => {
    calls.push({ command, args });
    return { status: 422, contentType: "application/json", body: '{"error":"invalid machine"}' };
  }) as typeof invoke;
  const response = await desktopFetch("/api/machines", { method: "POST", body: "{}" }, call);
  expect(calls).toEqual([{ command: "dashboard_request", args: { request: {
    path: "/api/machines", method: "POST", body: "{}",
  } } }]);
  expect(response.status).toBe(422);
  expect(await response.json()).toEqual({ error: "invalid machine" });
});

test("native transport handles no-content responses", async () => {
  const call = (async () => ({ status: 204, contentType: "application/json", body: "" })) as typeof invoke;
  expect((await desktopFetch("/api/machines/test", { method: "DELETE" }, call)).status).toBe(204);
});

test("native transport rejects cancellation while an IPC request is pending", async () => {
  const call = (() => new Promise(() => {})) as typeof invoke;
  const controller = new AbortController();
  const response = desktopFetch("/api/metrics", { signal: controller.signal }, call);
  controller.abort();
  await expect(response).rejects.toMatchObject({ name: "AbortError" });
});

test("native transport does not dispatch an already aborted mutation", async () => {
  let calls = 0;
  const call = (async () => { calls++; }) as typeof invoke;
  const controller = new AbortController();
  controller.abort();
  await expect(desktopFetch("/api/cache", { method: "DELETE", signal: controller.signal }, call))
    .rejects.toMatchObject({ name: "AbortError" });
  expect(calls).toBe(0);
});
