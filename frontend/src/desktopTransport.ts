import { invoke, isTauri } from "@tauri-apps/api/core";

interface DesktopResponse { status: number; contentType: string; body: string }

// Keep the browser transport for the explicit `serve` command.
export function dashboardFetch(path: string, init: RequestInit): Promise<Response> {
  if (!isTauri()) return fetch(path, init);
  return desktopFetch(path, init);
}

export async function desktopFetch(
  path: string,
  init: RequestInit,
  call: typeof invoke = invoke,
): Promise<Response> {
  if (init.body != null && typeof init.body !== "string") {
    throw new TypeError("Desktop dashboard requests require a JSON string body");
  }
  const signal = init.signal;
  signal?.throwIfAborted();
  return new Promise<Response>((resolve, reject) => {
    const abort = () => reject(signal?.reason ?? new DOMException("Aborted", "AbortError"));
    signal?.addEventListener("abort", abort, { once: true });
    call<DesktopResponse>("dashboard_request", {
      request: { path, method: init.method ?? "GET", body: init.body ?? null },
    }).then(result => {
      resolve(new Response(result.status === 204 ? null : result.body, {
        status: result.status, headers: { "Content-Type": result.contentType },
      }));
    }).catch(reject).finally(() => signal?.removeEventListener("abort", abort));
  });
}
