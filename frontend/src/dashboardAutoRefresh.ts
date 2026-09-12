export interface DashboardAutoRefreshOptions {
  intervalSeconds: number;
  isLoading: () => boolean;
  refresh: () => unknown | Promise<unknown>;
  reportError?: (error: unknown) => void;
  now?: () => number;
  window?: Pick<Window, "setInterval" | "clearInterval" | "addEventListener" | "removeEventListener">;
  document?: Pick<Document, "visibilityState" | "addEventListener" | "removeEventListener">;
}

export function startDashboardAutoRefresh(options: DashboardAutoRefreshOptions): () => void {
  const targetWindow = options.window ?? window;
  const targetDocument = options.document ?? document;
  const now = options.now ?? Date.now;
  const intervalMilliseconds = Math.max(options.intervalSeconds, 1) * 1_000;
  let nextRefreshAt = now() + intervalMilliseconds;

  const refreshIfDue = () => {
    const current = now();
    if (current < nextRefreshAt || options.isLoading()) return;
    nextRefreshAt = current + intervalMilliseconds;
    void Promise.resolve(options.refresh()).catch((error) => options.reportError?.(error));
  };
  const refreshWhenVisible = () => {
    if (targetDocument.visibilityState !== "hidden") refreshIfDue();
  };

  const timer = targetWindow.setInterval(refreshIfDue, intervalMilliseconds);
  targetWindow.addEventListener("focus", refreshWhenVisible);
  targetDocument.addEventListener("visibilitychange", refreshWhenVisible);

  return () => {
    targetWindow.clearInterval(timer);
    targetWindow.removeEventListener("focus", refreshWhenVisible);
    targetDocument.removeEventListener("visibilitychange", refreshWhenVisible);
  };
}
