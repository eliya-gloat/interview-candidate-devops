#!/usr/bin/env python3
"""Passive interview audit hook: append one JSON line per prompt / tool call.

Never writes to stdout (UserPromptSubmit stdout would be injected into the
session) and always exits 0, so it can neither block nor alter a tool call.
"""
import json
import os
import sys
import time

# INTERVIEW_AUDIT_LOG wins (bootstrap's preflight probe redirects with it), then
# argv[1] which bootstrap bakes with the real sandbox path, then the default.
# Never resolve the path from $HOME.
AUDIT_LOG = (
    os.environ.get("INTERVIEW_AUDIT_LOG")
    or (sys.argv[1] if len(sys.argv) > 1 else "")
    or "/tmp/interview-sandbox/evidence/audit.jsonl"
)
MAX_FIELD = 8000


def clip(value):
    text = value if isinstance(value, str) else json.dumps(value, default=str)
    if len(text) > MAX_FIELD:
        return text[:MAX_FIELD] + "...[clipped %d chars]" % (len(text) - MAX_FIELD)
    return text


def clip_obj(value):
    """Keep structure when it is small enough; fall back to a clipped string."""
    if len(json.dumps(value, default=str)) <= MAX_FIELD:
        return value
    return clip(value)


def main():
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        payload = {"_unparsed_stdin": clip(raw)}

    event = payload.get("hook_event_name") or "unknown"
    record = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + "Z",
        "event": event,
        "session_id": payload.get("session_id"),
        "cwd": payload.get("cwd"),
    }

    if event == "UserPromptSubmit":
        # Fall back to the whole payload rather than log an empty prompt.
        record["prompt"] = clip(payload.get("prompt") or payload)
    else:
        record["tool_name"] = payload.get("tool_name")
        # Pairs PreToolUse with PostToolUse: a tool_use_id that never gets a
        # PostToolUse line is a call that was attempted but not executed.
        record["tool_use_id"] = payload.get("tool_use_id")
        if event == "PreToolUse":
            record["tool_input"] = clip_obj(payload.get("tool_input", {}))
        elif event == "PostToolUse":
            record["executed"] = True

    if "_unparsed_stdin" in payload:
        record["raw"] = payload["_unparsed_stdin"]

    os.makedirs(os.path.dirname(AUDIT_LOG), exist_ok=True)
    with open(AUDIT_LOG, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, default=str, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # never let the hook surface as a tool failure
        try:
            with open(os.path.join(os.path.dirname(AUDIT_LOG), "audit-hook.err"), "a") as fh:
                fh.write("%s %r\n" % (time.time(), exc))
        except Exception:
            pass
    sys.exit(0)
