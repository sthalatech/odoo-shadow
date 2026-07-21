#!/usr/bin/env python3
"""Extract an opencode session transcript from a workspace's opencode.db.

Usage: extract_opencode_session.py <opencode.db> <session_id> [session_id...]
  (no session_id => all sessions, in time order)

Emits JSONL to stdout: one record per message-part, in session->message->part
order. Each record: {session, session_title, agent, model, msg_seq, part_seq,
time, type, role, text, tool, tool_input, tool_output, reasoning}.

Faithful to the opencode schema: parts have type text/reasoning/tool/step-start/
step-finish. We keep reasoning (the agent's thinking), tool calls (read/edit/bash
+ their input/output), and text (final assistant messages + the user task).
"""
import sys, sqlite3, json

DB = sys.argv[1]
want = sys.argv[2:]  # session ids; empty => all

c = sqlite3.connect(DB)
c.row_factory = sqlite3.Row

sess_q = "select id, title, agent, model, time_created from session order by time_created"
rows = list(c.execute(sess_q))
if want:
    rows = [r for r in rows if r["id"] in want]

for s in rows:
    sid = s["id"]
    meta = {
        "session": sid,
        "session_title": s["title"],
        "agent": s["agent"],
        "model": json.loads(s["model"]) if s["model"] else None,
    }
    # emit a session-start marker
    print(json.dumps({**meta, "kind": "session-start", "time": s["time_created"]}))
    # messages in order
    msgs = list(c.execute(
        "select id, time_created, data from message where session_id=? order by time_created",
        (sid,)))
    for mi, m in enumerate(msgs):
        mid = m["id"]
        mdata = json.loads(m["data"]) if m["data"] else {}
        role = mdata.get("role") or mdata.get("type") or "?"
        parts = list(c.execute(
            "select id, time_created, data from part where message_id=? order by time_created",
            (mid,)))
        for pi, p in enumerate(parts):
            pd = json.loads(p["data"]) if p["data"] else {}
            rec = {
                **meta,
                "kind": "part",
                "msg_seq": mi,
                "part_seq": pi,
                "time": p["time_created"],
                "type": pd.get("type"),
                "role": role,
                "text": pd.get("text", ""),
            }
            if pd.get("type") == "tool":
                st = pd.get("state") or {}
                rec["tool"] = pd.get("tool")
                rec["tool_state"] = st.get("status")
                rec["tool_input"] = st.get("input")
                rec["tool_output"] = st.get("output")
                rec["tool_error"] = st.get("error")
            if pd.get("type") == "step-finish":
                rec["reason"] = pd.get("reason")
                rec["tokens"] = pd.get("tokens")
            print(json.dumps(rec, default=str))
    print(json.dumps({**meta, "kind": "session-end"}))
