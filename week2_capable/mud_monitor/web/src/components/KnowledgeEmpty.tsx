import { useEffect, useState } from "react";

/**
 * The "agent has never run" state.
 *
 * It names the path the monitor actually resolved, because a missing file and a
 * file the monitor is looking for in the wrong directory are indistinguishable
 * otherwise — which is exactly the bug that had the telnet and manager pages
 * reporting "logging is off" while the daemon was happily writing elsewhere
 * (api/config/initializers/mud_monitor.rb).
 */
export default function KnowledgeEmpty() {
  const [ dir, setDir ] = useState<string | null>(null);

  useEffect(() => {
    fetch("/api/v1/health")
      .then((res) => (res.ok ? (res.json() as Promise<{ boukensha_dir: string }>) : null))
      .then((health) => setDir(health?.boukensha_dir ?? null))
      .catch(() => setDir(null));
  }, []);

  return (
    <p className="empty">
      No knowledge file yet — the agent writes <code>knowledge.sqlite3</code> the first time it looks at a room.
      {dir && (
        <>
          {" "}
          The monitor is looking in <code>{dir}</code>; set <code>MUD_KNOWLEDGE_DB</code> if that is the wrong
          place.
        </>
      )}
    </p>
  );
}
