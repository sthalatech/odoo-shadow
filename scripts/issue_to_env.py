#!/usr/bin/env python3
"""GitHub issue -> odoo-synth environment + AI agent launcher.

Invoked by .github/workflows/issue-env.yml on the `issues` webhook (opened).
It:

  1. Matches the issue's repo URL to an odoo-synth *profile* whose addons repo
     is the same, picks the profile's latest successful mask run (masked dump),
     and creates a Coder environment from it. This matches the env template
     preset the Coder dashboard would offer for that repo.
  2. Labels the env with the issue # + a short slug of the issue title
     (the Coder workspace name, e.g. `iss-42-fix-login-500`).
  3. Waits for the env to reach running, then invokes the agent headlessly
     inside it (opencode run / claude -p), passing the issue details as the
     task and the project system prompt as context. The agent + system prompt
     come from the matched profile (per-preset config), with env-var / global-
     file fallbacks.
  4. superpowers (the agentic-skills plugin baked into the golden AMI) loads
     inside the agent's session and drives it autonomously through the task
     (brainstorm -> plan -> git-worktree -> TDD -> review -> finish branch/PR).
     The env startup script stages the per-profile prompt as AGENT_CONTEXT.md /
     AGENT.md; this launcher overlays the issue/task specifics.

Inputs come from env vars set by the workflow:
  ISSUE_NUMBER, ISSUE_TITLE, ISSUE_BODY, ISSUE_URL, ISSUE_REPO_URL,
  ODOO_SYNTH_AGENT (default opencode; profile.agent_name wins when set),
  ODOO_SYNTH_MAX_ITER (kept for compat; the agent self-drives via superpowers),
  ODOO_SYNTH_AGENT_TIMEOUT (wall-clock cost guard, default 3600s),
  ODOO_SYNTH_UPGRADE_MODULES (optional comma-list, else profile-discovered),
  ODOO_SYNTH_BRANCH_HINT (optional repo branch override; else profile ref).

Exit codes: 0 = env created + agent launched; 1 = no matching profile; 2 = env
create failed; 3 = env did not become running; 4 = agent launch failed.
"""
from __future__ import annotations
import os
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "controlpanel"))

from backend import config, environments, store  # noqa: E402


def _log(msg: str) -> None:
    print(f"[issue-to-env] {msg}", flush=True)


def _normalize_repo(url: str) -> str:
    """Normalize a git URL for matching: lowercase, strip scheme/user/token/.git,
    trailing slash. `git@github.com:org/repo.git` and
    `https://github.com/org/repo` both -> `github.com/org/repo`."""
    if not url:
        return ""
    u = url.strip()
    if u.startswith("git@") or u.startswith("ssh://"):
        # git@github.com:org/repo(.git)  ->  github.com/org/repo
        u = re.sub(r"^(git@|ssh://)", "", u)
        u = u.replace(":", "/", 1)
    # strip any embedded creds (https://user:token@host/...)
    parts = urlsplit(u)
    host_path = (parts.netloc + parts.path) if parts.scheme else u
    host_path = host_path.split("@")[-1]  # drop user@ if present
    host_path = host_path.rstrip("/")
    if host_path.endswith(".git"):
        host_path = host_path[:-4]
    return host_path.lower()


def _short_slug(title: str, maxlen: int = 24) -> str:
    """Coerce an issue title into a short url-safe slug for the workspace name."""
    s = (title or "").strip().lower()
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    if not s:
        s = "task"
    if len(s) > maxlen:
        s = s[:maxlen].rstrip("-")
    return s or "task"


def _workspace_label(issue_number: str, title: str) -> str:
    """issue # + short name, e.g. `iss-42-fix-login-500`."""
    n = re.sub(r"[^0-9]", "", issue_number or "")
    return f"iss-{n or 'x'}-{_short_slug(title)}"


def match_profile(repo_url: str) -> tuple[str | None, dict | None]:
    """Find the profile whose addons repo matches `repo_url` (normalized host+path
    equality). Prefer one with a built image (image_status == ready). Returns
    (profile_id, profile) or (None, None) when nothing matches."""
    target = _normalize_repo(repo_url)
    if not target:
        return None, None
    profiles = store.list_profiles(limit=200)
    ready, other = None, None
    for p in profiles:
        pa = _normalize_repo(p.get("addons_git_url") or "")
        if pa and pa == target:
            if p.get("image_status") == "ready" and p.get("image_uri"):
                if ready is None:
                    ready = p
            elif other is None:
                other = p
    chosen = ready or other
    return (chosen["id"], chosen) if chosen else (None, None)


def latest_successful_mask_run(profile_id: str) -> str | None:
    """Newest succeeded mask run for the profile that produced a masked dump."""
    for r in store.list_runs(limit=200):
        if (r.get("operation") == "mask" and r.get("status") == "succeeded"
                and r.get("profile_id") == profile_id):
            full = store.get_run(r["id"]) or {}
            if (full.get("result") or {}).get("masked_dump_s3_uri"):
                return r["id"]
    return None


def main() -> int:
    issue_number = os.environ.get("ISSUE_NUMBER", "").strip()
    issue_title = os.environ.get("ISSUE_TITLE", "").strip()
    issue_body = os.environ.get("ISSUE_BODY", "").strip()
    issue_url = os.environ.get("ISSUE_URL", "").strip()
    issue_repo = os.environ.get("ISSUE_REPO_URL", "").strip()
    agent = os.environ.get("ODOO_SYNTH_AGENT", "opencode").strip() or "opencode"
    max_iter = int(os.environ.get("ODOO_SYNTH_MAX_ITER", "15") or "15")
    upgrade_modules = os.environ.get("ODOO_SYNTH_UPGRADE_MODULES", "").strip()
    branch_hint = os.environ.get("ODOO_SYNTH_BRANCH_HINT", "").strip()

    if not issue_repo:
        _log("ERROR: ISSUE_REPO_URL not set")
        return 1
    if not config.environments_configured():
        _log("ERROR: developer environments are not configured "
             "(CODER_URL + CODER_SESSION_TOKEN + odoo-synth-env template)")
        return 1

    _log(f"issue #{issue_number}: {issue_title!r}")
    _log(f"repo: {issue_repo}  -> normalized {_normalize_repo(issue_repo)}")

    pid, profile = match_profile(issue_repo)
    if not pid:
        _log(f"ERROR: no odoo-synth profile matches repo {issue_repo}; "
             "create+build+mask a profile for it first (odoo-synth profile create)")
        return 1
    _log(f"matched profile {pid} ({profile.get('label')}) "
         f"image_status={profile.get('image_status')}")

    run_id = latest_successful_mask_run(pid)
    if not run_id:
        _log(f"ERROR: profile {pid} has no succeeded mask run with a dump; "
             "run `odoo-synth run mask --profile <id>` first")
        return 1
    _log(f"using masked dump from mask run {run_id}")

    repo_branch = branch_hint or profile.get("addons_git_ref") or ""
    label = _workspace_label(issue_number, issue_title)
    issue_ref = f"#{issue_number}" if issue_number else issue_url

    # The post-launch module upgrade is generic (any repo). Scope it to the
    # profile's discovered installed modules when not overridden; empty =>
    # `-u all` (the template default).
    if not upgrade_modules:
        mods = profile.get("installed_modules") or []
        if mods:
            upgrade_modules = ",".join(mods)

    _log(f"creating env: name={label} issue={issue_ref} branch={repo_branch} "
         f"upgrade_modules={'all' if not upgrade_modules else f'{len(upgrade_modules.split(chr(44)))} modules'}")
    try:
        env_id = environments.create(
            source_run_id=run_id, issue=issue_ref, dump_s3_uri=None,
            repo_url=profile.get("addons_git_url"), repo_branch=repo_branch,
            profile_id=pid, name=label, upgrade_modules=upgrade_modules)
    except Exception as exc:  # noqa: BLE001
        _log(f"ERROR: env create failed: {exc}")
        return 2
    _log(f"env created: env_id={env_id} workspace={label}")

    _log("waiting for the workspace to reach running ...")
    wait_timeout = int(os.environ.get("ODOO_SYNTH_WAIT_TIMEOUT", "1200") or "1200")
    if not environments.wait_for_env(env_id, timeout=wait_timeout):
        _log("ERROR: env did not reach running in time")
        return 3
    _log("env is running; staging agent context + launching agent")

    task = f"Resolve GitHub issue {issue_ref}: {issue_title}"
    if issue_url:
        task += f"\nIssue URL: {issue_url}"
    if issue_body:
        task += f"\n\nIssue body:\n{issue_body[:8000]}"

    # The agent + system prompt come from the matched profile (per-preset
    # config), with env-var / global-file fallbacks so the defaults still work
    # for profiles that haven't set them.
    agent = (profile.get("agent_name") or agent).strip() or "opencode"
    system_prompt = (profile.get("agent_system_prompt") or "").strip()
    if not system_prompt:
        sp_path = REPO_ROOT / environments.AGENT_SYSTEM_PROMPT_PATH
        try:
            if sp_path.exists():
                system_prompt = sp_path.read_text()
        except Exception:  # noqa: BLE001
            pass
    # Wall-clock cost guard (replaces ralph's --max-iterations cap).
    agent_timeout = int(os.environ.get("ODOO_SYNTH_AGENT_TIMEOUT", "3600") or "3600")

    try:
        res = environments.run_agent(
            env_id, task, agent=agent, max_iterations=max_iter,
            issue=issue_ref, system_prompt=system_prompt,
            timeout=agent_timeout)
    except Exception as exc:  # noqa: BLE001
        _log(f"ERROR: agent launch failed: {exc}")
        return 4
    _log(f"agent finished: exit={res['exit_code']} workspace={res['workspace']}")
    if res["output"]:
        _log("agent output (head):\n" + "\n".join(res["output"].splitlines()[:40]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
