#!/usr/bin/env bash
# Wait for the 3 issue launchers to finish, then capture final opencode
# transcripts for each workspace. Run detached (it self-completes).
set -uo pipefail
REPO="/home/exedev/odoo-synth-coder"
CAP="$REPO/docs/demo/captures"
declare -A ENV_OF=( [501]=b52640b376 [502]=b15571759e [504]=b72fa45ebd )
log(){ echo "[$(date -u +%H:%M:%S)] $*" >> "$CAP/capture.log"; }
log "wait_and_capture_all start"
# Wait until no issue_to_env.py launcher process remains.
while pgrep -f "/opt/odoo-synth-coder/scripts/issue_to_env.py" >/dev/null 2>&1; do
  sleep 30
done
log "all launchers finished; capturing final transcripts"
sleep 10  # let opencode flush its DB (WAL -> main)
for iss in 501 502 504; do
  env="${ENV_OF[$iss]}"
  log "capturing #$iss env=$env"
  bash "$CAP/pull_workspace_transcript.sh" "$env" "$CAP/iss${iss}_final.jsonl" 2>&1 | tee -a "$CAP/capture.log"
done
log "done"
