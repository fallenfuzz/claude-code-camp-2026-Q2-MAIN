import { useState } from "react";
import type { Entry } from "../../api/types";

// State a hook appended to the conversation on the model's behalf — the
// `[here]` block, in the MUD deployment. It sits immediately before the request
// that carried it, which is what makes an assistant thanking us "for the
// context" traceable without opening the request drawer.
//
// Collapsed to its first line by default: the block is re-rendered every
// iteration and is usually identical to the last one, and `changed` is how the
// server says which is which.
export default function InjectedContext({ entry }: { entry: Entry }) {
  const [open, setOpen] = useState(false);
  const lines = (entry.content ?? "").split("\n");
  const unchanged = entry.changed === false;

  return (
    <div className={unchanged ? "injected-card injected-unchanged" : "injected-card"}>
      <button type="button" className="injected-head" aria-expanded={open} onClick={() => setOpen(!open)}>
        <span className="task-group-caret">{open ? "▾" : "▸"}</span>
        <span className="injected-label">Context injected</span>
        {entry.source && <span className="task-group-meta">{entry.source}</span>}
        {unchanged && <span className="task-group-meta">unchanged</span>}
        <span className="task-group-spacer" />
        <span className="injected-peek">{lines[0]}</span>
      </button>
      {open && <pre className="injected-body">{entry.content}</pre>}
    </div>
  );
}
