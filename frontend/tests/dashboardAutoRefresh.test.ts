import { expect, test } from "bun:test";
import { startDashboardAutoRefresh } from "../src/dashboardAutoRefresh";

function eventTarget() {
  const listeners = new Map<string, Set<() => void>>();
  return {
    addEventListener(type: string, listener: EventListenerOrEventListenerObject) {
      const callback = listener as () => void;
      const callbacks = listeners.get(type) ?? new Set<() => void>();
      callbacks.add(callback);
      listeners.set(type, callbacks);
    },
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject) {
      listeners.get(type)?.delete(listener as () => void);
    },
    dispatch(type: string) {
      for (const listener of listeners.get(type) ?? []) listener();
    },
    listenerCount(type: string) { return listeners.get(type)?.size ?? 0; },
  };
}

test("refreshes on schedule and catches up when a throttled Tauri window regains focus", async () => {
  const windowEvents = eventTarget();
  const documentEvents = eventTarget();
  let interval: (() => void) | undefined;
  let cleared: number | undefined;
  let currentTime = 0;
  let refreshes = 0;
  const stop = startDashboardAutoRefresh({
    intervalSeconds: 20,
    isLoading: () => false,
    refresh: () => { refreshes++; },
    now: () => currentTime,
    window: {
      ...windowEvents,
      setInterval: ((callback: TimerHandler) => {
        interval = callback as () => void;
        return 7;
      }) as Window["setInterval"],
      clearInterval: ((id: number) => { cleared = id; }) as Window["clearInterval"],
    },
    document: { ...documentEvents, visibilityState: "visible" },
  });

  currentTime = 20_000;
  interval?.();
  await Promise.resolve();
  expect(refreshes).toBe(1);

  currentTime = 60_000;
  windowEvents.dispatch("focus");
  await Promise.resolve();
  expect(refreshes).toBe(2);

  stop();
  expect(cleared).toBe(7);
  expect(windowEvents.listenerCount("focus")).toBe(0);
  expect(documentEvents.listenerCount("visibilitychange")).toBe(0);
});

test("defers an overdue refresh while data is loading", async () => {
  const windowEvents = eventTarget();
  const documentEvents = eventTarget();
  let currentTime = 20_000;
  let loading = true;
  let refreshes = 0;
  const stop = startDashboardAutoRefresh({
    intervalSeconds: 20,
    isLoading: () => loading,
    refresh: () => { refreshes++; },
    now: () => currentTime,
    window: {
      ...windowEvents,
      setInterval: (() => 1) as Window["setInterval"],
      clearInterval: (() => undefined) as Window["clearInterval"],
    },
    document: { ...documentEvents, visibilityState: "visible" },
  });

  currentTime = 40_000;
  windowEvents.dispatch("focus");
  expect(refreshes).toBe(0);
  loading = false;
  documentEvents.dispatch("visibilitychange");
  await Promise.resolve();
  expect(refreshes).toBe(1);
  stop();
});
