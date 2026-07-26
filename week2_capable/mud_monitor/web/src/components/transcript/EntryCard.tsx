import type { Entry } from "../../api/types";
import CtxChip from "../CtxChip";
import InjectedContext from "./InjectedContext";
import { ToolCard } from "./ToolCard";
import TurnStrip from "./TurnStrip";
import type { ToolRollupInfo } from "./types";

export interface EntryCardProps {
  entry: Entry;
  /** For the `assistant`/tool-use `CtxChip`. */
  contextWindow: number | null | undefined;
  /** For the `turn_end` `TurnStrip`. */
  maxTurnTokens: number | null | undefined;
  onOpenRequest: (requestSeq: number) => void;
  coarse: boolean;
  /** A model-chosen `tool` entry's span rollup — null/absent for anything else. */
  toolRollup?: ToolRollupInfo | null;
  /** The `chat` span's own measured duration for THIS `assistant` entry —
   *  distinct from `dt_ms`, which also charges the model for our own
   *  request/response serialization either side of the wire call. */
  modelMs?: number | null;
  /** The `turn` span's own measured duration for a `turn_end` entry. */
  turnDurationMs?: number | null;
}

// One parsed session-log Entry, rendered. The generic per-entry renderer
// shared by the legacy linear transcript and the story tree — extracted from
// SessionDetail.tsx's `TranscriptEntry` (session_story_tree.md Phase 3), which
// is why the "how do I know the model latency / turn duration" values arrive
// as plain props rather than a lookup this component builds itself: the two
// callers compute them from different sources (a flat-entries scan for the
// legacy tree, `trace.spans` directly for the story tree).
export default function EntryCard({
  entry,
  contextWindow,
  maxTurnTokens,
  onOpenRequest,
  coarse,
  toolRollup,
  modelMs,
  turnDurationMs,
}: EntryCardProps) {
  switch (entry.type) {
    case "user":
      return (
        <div className="msg msg-user">
          <div className="msg-role">
            <span>User</span>
          </div>
          <div className="msg-body">{entry.text}</div>
        </div>
      );

    case "compaction":
      return (
        <div className="divider divider-compaction">
          ↻ context compacted — {entry.dropped} message{entry.dropped === 1 ? "" : "s"} dropped
        </div>
      );

    case "clear":
      return (
        <div className="divider divider-compaction">
          ⌫ conversation cleared — {entry.dropped} message{entry.dropped === 1 ? "" : "s"} dropped
        </div>
      );

    case "request":
      // The point a model call was made. The button opens the sidebar on THIS
      // request's payload (system + tools + wire messages) — kept out of the
      // transcript body so the narrative stays readable.
      return (
        <div className="request-marker">
          <button
            type="button"
            className="request-btn"
            onClick={() => entry.request_seq != null && onOpenRequest(entry.request_seq)}
            title="View the exact payload sent to the model on this call"
          >
            🧠 view request
            {entry.message_count != null && (
              <span className="request-btn-count">{entry.message_count} msg{entry.message_count === 1 ? "" : "s"}</span>
            )}
          </button>
        </div>
      );

    case "turn_end":
      return <TurnStrip entry={entry} maxTurnTokens={maxTurnTokens} turnDurationMs={turnDurationMs} coarse={coarse} />;

    case "plan":
      return (
        <div className="msg msg-assistant msg-preamble">
          <div className="msg-role">
            <span>Plan</span>
            <span className="usage">before tool call</span>
          </div>
          <div className="msg-body">{entry.text}</div>
        </div>
      );

    case "assistant": {
      if (entry.text?.startsWith("(tool use")) {
        return (
          <div className="tool-marker">
            <span>{entry.text}</span>
            <CtxChip
              usage={entry.usage}
              running={entry.running_turn_tokens}
              contextWindow={contextWindow}
              maxTurnTokens={maxTurnTokens}
              provider={entry.provider}
              model={entry.model}
              costUsd={entry.cost_usd}
              modelMs={modelMs}
              coarse={coarse}
            />
          </div>
        );
      }
      return (
        <div className="msg msg-assistant">
          <div className="msg-role">
            <span>Assistant</span>
            <span className="usage">{entry.stop_reason && <>stop: {entry.stop_reason}</>}</span>
          </div>
          <div className="msg-body">{entry.text}</div>
          {entry.usage && (
            <div className="msg-foot">
              <CtxChip
                usage={entry.usage}
                running={entry.running_turn_tokens}
                contextWindow={contextWindow}
                maxTurnTokens={maxTurnTokens}
                provider={entry.provider}
                model={entry.model}
                costUsd={entry.cost_usd}
                modelMs={modelMs}
                coarse={coarse}
              />
            </div>
          )}
        </div>
      );
    }

    case "reasoning":
      return (
        <div className="msg msg-assistant msg-reasoning">
          <div className="msg-role">
            <span>Reasoning</span>
          </div>
          <div className="msg-body">
            {entry.redacted || !entry.text?.trim() ? (
              <span className="muted">(reasoning hidden)</span>
            ) : (
              entry.text
            )}
          </div>
        </div>
      );

    case "tool":
      // A hook-initiated call reaches here via AutomaticCall separately in the
      // legacy tree; a model-chosen one carries the id of its own
      // `tool.<name>` span, whose rollup becomes this card's footer.
      return <ToolCard entry={entry} rollup={toolRollup} coarse={coarse} />;

    case "injected_context":
      return <InjectedContext entry={entry} />;

    case "context_transform":
      // Only reachable when the log lost the call this belongs to; the normal
      // path folds it into the tool card.
      return (
        <div className="injected-card">
          <div className="injected-head">↪ model received (call {entry.call_id ?? "?"})</div>
          <pre className="injected-body">{entry.content}</pre>
        </div>
      );

    case "unknown":
      return (
        <div className="msg msg-unknown">
          <div className="msg-role">
            <span>{String(entry.raw?.phase ?? "unknown")}</span>
          </div>
          <div className="msg-body">
            <pre>{JSON.stringify(entry.raw, null, 2)}</pre>
          </div>
        </div>
      );

    default:
      return null;
  }
}
