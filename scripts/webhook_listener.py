#!/usr/bin/env python3
"""GitHub webhook listener -> odoo-synth env + opencode agent launcher.

Runs ON THE CODER SERVER (the always-on control plane at CODER_SERVER_IP), NOT
on a dev VM. GitHub POSTs `issues` events from the *profile's addons repo*
(e.g. IshaFoundationIT/erp.life.in) to this listener; it verifies the
HMAC-SHA256 signature with a shared webhook secret, and on `issue.opened` runs
scripts/issue_to_env.py in a background thread (GitHub gets a fast 200 while the
env boots + agent runs, which takes many minutes).

Why the Coder server host:
  - It is the only always-on box in the stack; a dev VM is ephemeral.
  - It already has CODER_URL + CODER_SESSION_TOKEN (it runs `coder server`).
  - It has AWS creds for the dumps bucket, so it can read the S3-backed profile
    + run stores (the "latest preset for that repo" resolver) without this dev
    VM being up.
  - `coder create` talks to the Coder API on localhost.

The launcher (scripts/issue_to_env.py) is host-agnostic: it matches the issue's
repo URL -> profile (from S3) -> latest successful mask run -> `coder create`
with the profile's params (= the same preset the Coder dashboard offers), then
labels the env `iss-<n>-<slug>` and drives opencode via ralph-wiggum.

Deployment (see deploy/13_webhook_listener.sh):
  - opens a 2nd SG port on the Coder server (default 8080) to 0.0.0.0/0 so GitHub
    can reach the listener; installs the repo + python deps + a systemd unit.
  - GitHub repo -> Settings -> Webhooks -> Add webhook:
      Payload URL: http://<CODER_SERVER_IP>:8080/webhook
      Content type: application/json
      Events: Issues
      Secret: <GITHUB_WEBHOOK_SECRET>  (must match the systemd unit's env)

Env vars (systemd unit / EnvironmentFile):
  GITHUB_WEBHOOK_SECRET  REQUIRED -- shared secret for HMAC verification.
  WEBHOOK_PORT           default 8080.
  WEBHOOK_BIND           default 0.0.0.0 (GitHub reaches it directly; set
                         127.0.0.1 if you put a reverse proxy in front).
  CODER_URL, CODER_SESSION_TOKEN, AWS_*  inherited so the launcher can drive
                         Coder + read the S3 profile/run stores.
"""
from __future__ import annotations
import hashlib
import hmac
import json
import os
import subprocess
import threading
from pathlib import Path

from flask import Flask, request, abort

REPO_ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = REPO_ROOT / "scripts" / "issue_to_env.py"

app = Flask(__name__)


def _webhook_secret() -> bytes:
    s = os.environ.get("GITHUB_WEBHOOK_SECRET", "")
    return s.encode() if s else b""


def _verify_signature(payload: bytes, sig_header: str | None) -> bool:
    """GitHub signs the raw body with HMAC-SHA256 using the webhook secret and
    sends `X-Hub-Signature-256: sha256=<hex>`. Constant-time compare. Fails
    closed: no secret / no header -> reject (never run the env launcher on an
    unauthenticated POST)."""
    secret = _webhook_secret()
    if not secret or not sig_header or not sig_header.startswith("sha256="):
        return False
    expected = hmac.new(secret, payload, hashlib.sha256).hexdigest()
    got = sig_header.split("=", 1)[1].strip()
    return hmac.compare_digest(expected, got)


def _run_launcher(env: dict) -> None:
    """Run the launcher in the background; output goes to the journal."""
    try:
        subprocess.run(
            ["python3", str(LAUNCHER)],
            env={**os.environ, **env},
            cwd=str(REPO_ROOT),
            capture_output=True, text=True, timeout=90 * 60, check=False,
        )
    except Exception:  # noqa: BLE001
        pass


@app.post("/webhook")
def webhook():
    payload = request.get_data()
    if not _verify_signature(payload, request.headers.get("X-Hub-Signature-256")):
        abort(401)
    event = request.headers.get("X-GitHub-Event", "")
    if event != "issues":
        return ("ignored: not an issues event\n", 200)
    try:
        data = json.loads(payload.decode() if isinstance(payload, bytes) else payload)
    except Exception:  # noqa: BLE001
        abort(400)
    action = data.get("action")
    if action != "opened":
        return (f"ignored: action={action}\n", 200)
    issue = data.get("issue") or {}
    repo = data.get("repository") or {}
    env = {
        "ISSUE_NUMBER": str(issue.get("number") or ""),
        "ISSUE_TITLE": issue.get("title") or "",
        "ISSUE_BODY": issue.get("body") or "",
        "ISSUE_URL": issue.get("html_url") or "",
        # the addons repo the issue belongs to -> matches an odoo-synth profile
        "ISSUE_REPO_URL": repo.get("clone_url") or "",
    }
    # fire-and-forget: env boot takes minutes; GitHub must not wait for it
    threading.Thread(target=_run_launcher, args=(env,), daemon=True).start()
    return (json.dumps({"accepted": True, "issue": env["ISSUE_NUMBER"]}), 200,
            {"Content-Type": "application/json"})


@app.get("/healthz")
def healthz():
    return ("ok\n", 200)


if __name__ == "__main__":
    port = int(os.environ.get("WEBHOOK_PORT", "8080"))
    host = os.environ.get("WEBHOOK_BIND", "0.0.0.0")
    app.run(host=host, port=port, debug=False)
