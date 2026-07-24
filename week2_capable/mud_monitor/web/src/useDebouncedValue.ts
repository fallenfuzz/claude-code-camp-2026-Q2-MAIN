import { useEffect, useState } from "react";

/**
 * Delays a value until it has stopped changing for `delayMs`.
 *
 * Used for the knowledge search boxes. Without it, every keystroke is a new
 * query, and `usePolling` clears its data on a query change — so typing
 * "temple" blanks the table six times and fires six requests at the file the
 * agent is writing. The other pages' filters get away with fetching per
 * keystroke because they are short codes; a free-text search is not.
 */
export function useDebouncedValue<T>(value: T, delayMs = 250): T {
  const [ debounced, setDebounced ] = useState(value);

  useEffect(() => {
    const timer = setTimeout(() => setDebounced(value), delayMs);
    return () => clearTimeout(timer);
  }, [ value, delayMs ]);

  return debounced;
}
