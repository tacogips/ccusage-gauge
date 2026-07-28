import type { Resource } from "solid-js";
import type { LoadStatusResponse } from "./api";

// Reading a Solid resource whose fetch rejected re-throws the stored error at
// every call site. This app has no ErrorBoundary, so one failed dashboard
// request would otherwise escape the reactive graph and freeze every
// downstream computation — the UI then hangs on whatever was last rendered
// (typically the blocking loader). Shielded resources read as `undefined`
// while errored; callers inspect `.error` to react to the failure.
export function shieldResource<T>(resource: Resource<T>): Resource<T | undefined> {
  const read = () => (resource.error != null ? undefined : resource());
  Object.defineProperties(read, {
    state: { get: () => resource.state },
    error: { get: () => resource.error },
    loading: { get: () => resource.loading },
    latest: { get: () => (resource.error != null ? undefined : resource()) },
  });
  return read as Resource<T | undefined>;
}

export function shouldBlockDashboard(input: {
  isInitialLoading: boolean;
  isRangeLoading: boolean;
  isFetching: boolean;
  hasFailedRequest: boolean;
  loadStatus?: LoadStatusResponse;
}): boolean {
  if (input.isRangeLoading) return true;
  if (!input.isInitialLoading) return false;
  if (input.loadStatus == null || !["ready", "failed"].includes(input.loadStatus.phase)) {
    return true;
  }
  // Collection is terminal. Requests still in flight justify the loader, but
  // once one has failed, waiting cannot make progress — render the dashboard
  // (or its error state) while terminal-state recovery retries missing data.
  return input.isFetching && !input.hasFailedRequest;
}
