import { useEffect, useRef, useState } from "react";
import { ApiRequestError } from "./client";

export const POLL_INTERVAL_MS = 3000;

/**
 * Refetch on an interval, but only while the tab is actually being looked at.
 *
 * The knowledge pages use this instead of `useEventStream` because knowledge is
 * a snapshot, not a log: an UPDATE to `rooms.visit_count` is not an event and
 * cannot be expressed as "entries after seq N", so there is nothing to tail.
 *
 * Two behaviours that matter more than they look:
 *  - a poll tick REPLACES data without blanking it first, so the table doesn't
 *    flash every 3s; only a change in `deps` (a new query) clears it;
 *  - `document.visibilityState` gates the timer, so a monitor left open on a
 *    background tab stops hammering the file the agent is writing.
 */
export function usePolling<T>(
  fetcher: () => Promise<T>,
  deps: unknown[],
  intervalMs: number = POLL_INTERVAL_MS,
): { data: T | null; error: string | null } {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);

  // Held in a ref so an inline arrow in the caller doesn't restart the timer on
  // every render — the deps array is the only thing that should do that.
  const fetcherRef = useRef(fetcher);
  fetcherRef.current = fetcher;

  useEffect(() => {
    let cancelled = false;
    let timer: ReturnType<typeof setInterval> | undefined;

    const load = () => {
      fetcherRef
        .current()
        .then((next) => {
          if (cancelled) return;
          setData(next);
          setError(null);
        })
        .catch((err) => {
          if (cancelled) return;
          setError(err instanceof ApiRequestError ? err.message : String(err));
        });
    };

    const start = () => {
      if (timer === undefined) timer = setInterval(load, intervalMs);
    };
    const stop = () => {
      if (timer !== undefined) {
        clearInterval(timer);
        timer = undefined;
      }
    };

    const onVisibilityChange = () => {
      if (document.visibilityState === "visible") {
        load(); // catch up immediately rather than waiting out an interval
        start();
      } else {
        stop();
      }
    };

    // The query changed, so the previous answer is now the wrong answer.
    setData(null);
    setError(null);
    load();
    if (document.visibilityState === "visible") start();
    document.addEventListener("visibilitychange", onVisibilityChange);

    return () => {
      cancelled = true;
      stop();
      document.removeEventListener("visibilitychange", onVisibilityChange);
    };
  }, [...deps, intervalMs]);

  return { data, error };
}
