#!/usr/bin/env python3
"""Bake opencode session JSONL transcripts into compact Act 2 render-line files.

Input:  issNNN_final.jsonl (from extract_opencode_session.py)
Output: issNNN.json  -- {issue, title, role, outcome, beats: [{name, lines:[...]}]}

Each render line:
  {cls, text, delay}
  cls in: prompt|ok|info|mut|tool|reason|warn|head|check
Beat classification (deterministic, from tool+position):
  1 BOOT     - before first skill/todowrite (reading AGENT_CONTEXT/AGENT.md)
  2 EXPLORE  - skill + todowrite + task (subagent dispatches), and subagent sessions
  3 DIAGNOSE - grep/read/glob/bash/reasoning in build session after explore
  4 FIX      - edit/str_replace/write tool calls   (empty if none)
  5 VERIFY   - bash containing odoo/pytest/chrome   (empty if none)
  6 PR       - bash with git commit/gh pr create, or text with PR url (external)
"""
import sys, json, os, re

CAP = os.path.dirname(os.path.abspath(__file__))

# External outcome knowledge (PRs/fixes happened in follow-up runs not in the
# captured transcript). Kept honest: only #501 has a PR.
OUTCOMES = {
    "iss501": {"pr": 505, "branch": "fix/participant-transfer-zero-amount-so",
               "card": "✅ PR #505 opened — fix/prs: zero-amount participant transfers"},
    "iss502": {"card": "🔍 Diagnosed — google_calendar sync mapped; fix pass ready"},
    "iss504": {"card": "🧠 Brainstormed — enforcement points identified; awaiting fix pass"},
}
ROLES = {"iss501": "Dev", "iss502": "BA", "iss504": "Tech Lead"}
TITLES = {
    "iss501": "#501 participant transfer",
    "iss502": "#502 Google Calendar resync",
    "iss504": "#504 Financial entity enforcing",
}

def short(path):
    if not path: return ""
    return path.replace("/home/dev/workspace/repo/", "")

def tool_summary(r):
    """One-line human summary of a tool call."""
    t = r.get("tool")
    ti = r.get("tool_input") or {}
    if t == "read":
        return f"read   {short(ti.get('filePath'))}"
    if t == "glob":
        return f"glob   {ti.get('pattern','')}"
    if t == "grep":
        return f"grep   {ti.get('pattern','')}"
    if t == "bash":
        c = str(ti.get("command","")).strip().splitlines()
        return f"$ {c[0][:70]}" if c else "$"
    if t == "edit" or t == "str_replace" or t == "write":
        return f"edit   {short(ti.get('filePath'))}"
    if t == "skill":
        return f"✦ skill: {ti.get('name') or ti.get('skill') or list(ti.values())[0]}"
    if t == "todowrite":
        todos = ti.get("todos") or []
        return f"☐ plan written: {len(todos)} phases"
    if t == "task":
        return f"→ @explore subagent dispatched"
    return f"{t}   {str(ti)[:50]}"

def todowrite_lines(r):
    ti = r.get("tool_input") or {}
    out = []
    for todo in (ti.get("todos") or []):
        mark = "☐"
        if todo.get("status") == "in_progress": mark = "▶"
        elif todo.get("status") == "completed": mark = "✓"
        out.append({"cls": "check", "text": f"  {mark} {todo.get('content','')}", "delay": 60})
    return out

def classify(records):
    """Assign each record a beat 1..6. Returns list of (beat, record)."""
    # find boundary indices in the BUILD session
    build = [r for r in records if r.get("agent") == "build"]
    # explore boundary: first skill or todowrite in build
    explore_start = None
    for i, r in enumerate(build):
        if r.get("tool") in ("skill", "todowrite"):
            explore_start = i; break
    # diagnose boundary: last task (subagent dispatch) in build, OR end of explore markers
    diagnose_start = None
    last_task = None
    for i, r in enumerate(build):
        if r.get("tool") == "task":
            last_task = i
    if last_task is not None:
        diagnose_start = last_task + 1
    elif explore_start is not None:
        diagnose_start = explore_start + 1

    # map build-record index -> beat
    def beat_for_build(i):
        if explore_start is None:
            return 1  # no skill/todo -> everything is BOOT/diagnose
        if i < explore_start: return 1
        if diagnose_start is None or i < diagnose_start: return 2
        return 3
    # override by tool type for fix/verify/pr
    def override(r, b):
        t = r.get("tool")
        if t in ("edit", "str_replace", "write"): return 4
        if t == "bash":
            c = str((r.get("tool_input") or {}).get("command","")).lower()
            if any(k in c for k in ("git commit","git push","gh pr","gh pr create","pull request")):
                return 6
            if any(k in c for k in ("odoo","pytest","chrome","python -m pytest","-u ","--test")):
                return 5
        return b
    build_beats = {}
    for i, r in enumerate(build):
        b = beat_for_build(i)
        b = override(r, b)
        build_beats[id(r)] = b
    # subagent (explore) sessions -> beat 2 always
    result = []
    for r in records:
        if r.get("kind") == "session-start" and r.get("agent") == "explore":
            result.append((2, r)); continue
        if r.get("agent") == "explore":
            result.append((2, r)); continue
        b = build_beats.get(id(r), 1)
        result.append((b, r))
    return result

BEAT_NAMES = {1:"BOOT",2:"EXPLORE",3:"DIAGNOSE",4:"FIX",5:"VERIFY",6:"PR"}

def render_line(r, beat):
    """Convert one record to a render line (or None to skip)."""
    k = r.get("kind")
    typ = r.get("type")
    if k == "session-start":
        if r.get("agent") == "explore":
            return {"cls":"mut","text":f"  └ @explore: {r.get('session_title','')[:60]}","delay":90}
        return {"cls":"head","text":f"● session: {r.get('session_title','')[:60]}","delay":120}
    if k == "session-end":
        return None
    if typ == "text":
        txt = (r.get("text") or "").strip()
        if not txt: return None
        role = (r.get("role") or "").lower()
        if role == "user" or "resolve github issue" in txt.lower()[:30]:
            return {"cls":"prompt","text":txt[:160].replace("\n"," "),"delay":120}
        return {"cls":"ok","text":txt[:140].replace("\n"," "),"delay":110}
    if typ == "reasoning":
        txt = (r.get("text") or "").strip()
        if not txt: return None
        return {"cls":"reason","text":f"  {txt[:120]}","delay":70}
    if typ == "tool":
        t = r.get("tool")
        if t == "todowrite":
            return None  # handled as multi-line by caller
        s = tool_summary(r)
        if not s: return None
        return {"cls":"tool","text":s,"delay":75}
    if typ in ("step-start","step-finish"):
        return None
    if typ is None:
        return None
    return None

# Per-subagent-session line budget: keep the dispatch header + a representative
# sample of its tool calls + its final summary, not every internal grep/read.
SUBAGENT_TOOL_BUDGET = 6

def bake(name):
    src = os.path.join(CAP, f"{name}_final.jsonl")
    rows = [json.loads(l) for l in open(src) if l.strip()]
    classified = classify(rows)
    beats = {i: [] for i in range(1,7)}
    seen_explore = set()
    sub_tool_count = {}
    for beat, r in classified:
        # subagent sessions: budget tool lines; keep header/reasoning/summary
        if r.get("agent") == "explore":
            sid = r.get("session")
            if r.get("kind") == "session-start":
                t = r.get("session_title")
                if t in seen_explore: continue
                seen_explore.add(t); sub_tool_count[sid] = 0
                ln = render_line(r, beat)
                if ln: beats[beat].append(ln)
                continue
            if r.get("type") == "tool":
                sub_tool_count[sid] = sub_tool_count.get(sid,0) + 1
                if sub_tool_count[sid] > SUBAGENT_TOOL_BUDGET: continue
            ln = render_line(r, beat)
            if ln: beats[beat].append(ln)
            continue
        if r.get("type") == "tool" and r.get("tool") == "todowrite":
            for ln in todowrite_lines(r):
                beats[beat].append(ln)
            continue
        ln = render_line(r, beat)
        if ln: beats[beat].append(ln)
    # PR beat: inject external outcome for iss501
    oc = OUTCOMES.get(name, {})
    if oc.get("pr"):
        beats[6].append({"cls":"ok","text":f"$ gh pr create --base uat --head {oc['branch']}","delay":90})
        beats[6].append({"cls":"ok","text":oc["card"],"delay":120})
    beat_list = [{"name":BEAT_NAMES[i],"lines":beats[i]} for i in range(1,7)]
    out = {"issue":name,"title":TITLES[name],"role":ROLES[name],
           "outcome":oc.get("card",""),"beats":beat_list}
    dst = os.path.join(CAP, f"{name}.json")
    with open(dst,"w") as f:
        json.dump(out,f,indent=1)
    print(f"{name}.json: "+" ".join(f"{BEAT_NAMES[i]}={len(beats[i])}" for i in range(1,7)))

if __name__ == "__main__":
    for n in ["iss501","iss502","iss504"]:
        bake(n)
