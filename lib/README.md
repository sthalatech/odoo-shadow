# odooshadow control panel → CLI (Phase C2)

The FastAPI web panel has been replaced by a single CLI: **`odooshadow`**
(lives at [`../cli/odooshadow`](../cli/odooshadow)). The CLI calls the **same
backend library modules** in `backend/` directly over an in-process call
boundary — there is no HTTP server any more. Run history and logs are still
persisted as YAML (profiles under `profiles/`, environments in `envs.yaml`)
and on S3 (runs + logs, **and profiles**), with Coder owning env lifecycle, so
everything the panel tracked survives across CLI invocations. Profile YAMLs
are mirrored to S3 (`<dumps-bucket>/<prefix>/profiles/<id>.yaml`) so a profile
created on one machine is visible on every other — this keeps the Coder template
presets complete no matter which host publishes them; `profiles/` is a local
cache that auto-populates from S3 on read.

> **User management** is no longer exposed here — use the native Coder CLI:
>   `coder users create alice@example.com` / `coder users list`.
> **Workspace creation** is via the Coder dashboard (presets) or
>   `coder create -t odooshadow-workspacer ...`. The CLI still launches/tears down
>   developer workspaces via `odooshadow workspace ...` (it calls `coder create`
>   under the hood).

## Install

```bash
bash deploy/00_install_prereqs.sh    # installs tools + symlinks odooshadow onto PATH
# or, manually:
sudo ln -sf /home/exedev/odooshadow-coder/cli/odooshadow /usr/local/bin/odooshadow
```

Run from anywhere — the CLI resolves the repo root from its own location and
adds `lib/` to `sys.path` so it can `from backend import …`.

## Commands

```
odooshadow --help
odooshadow profile create --label <l> --source-dsn postgresql://… [--ssh-* …] [--odoo-series 19.0 …]
odooshadow profile list [--json]
odooshadow profile show <id>
odooshadow profile update <id> [--label …] [--source-dsn …]
odooshadow profile delete <id>
odooshadow profile discover <id>            # synchronous; streams logs to stdout
odooshadow profile build <id>               # synchronous; streams logs to stdout
odooshadow profile images <id> [--json]
odooshadow profile images delete <id> --image <uri>
odooshadow profile masking-rules <id> [--json]
odooshadow profile masking-rules <id> --set <file|->   # update from YAML (file or stdin)
odooshadow profile masking-rules <id> --reset          # reset to discovered plan
odooshadow profile mask <id>                           # profile path (produces a dump)
odooshadow run mask --source-dsn <dsn> [--mask-profile …] [--produce-dump] [--ssh-* …]  # legacy inline
odooshadow run list [--json]
odooshadow run show <id>
odooshadow run logs <id> [--follow]                    # print stored logs; --follow polls
odooshadow workspace list [--json]
odooshadow workspace create --profile-id <id> | --source-run-id <id> | --dump-s3-uri s3://…
odooshadow workspace show <workspace_id>
odooshadow workspace password <workspace_id>
odooshadow workspace delete <workspace_id>
odooshadow workspace config
odooshadow config                            # non-secret infra summary
```

`--verbose` shows full tracebacks on error; otherwise errors print one line to
stderr and exit non-zero.

## How long-running ops work

`profile discover`, `profile build`, and `run mask` run **synchronously in the
foreground**. They create a run row (`store.create_run`), mark it `running`,
call the backend op (`discovery.run_discovery` / `build.run_build` /
`pipeline.run_operation`) with an `emit` sink that **prints each log line to
stdout AND appends it to the run's log table**, then `store.update_run` with the
result. This mirrors the panel's `_worker` exactly, minus the background thread
and SSE plumbing — so `odooshadow run logs <id>` replays the same persisted
logs afterwards.

## Architecture

```
cli/odooshadow            argparse CLI (this is the whole UI now)
lib/
  backend/                reusable library (unchanged)
    profiles.py           source-binding profiles + run_params
    discovery.py          discovery op + masking-rule validation
    build.py              provenance image build
    pipeline.py           mask op (Coder runner workspace)
    profile_store.py      one YAML file per profile under ../profiles/
                          (mirrored to S3; local dir is a cache)
    run_store.py          S3-backed runs + logs (s3://bucket/.../runs/<id>/)
    env_store.py          one YAML file (envs.yaml): env linkage + password ARNs
    store.py              thin facade delegating to the three stores (no SQLite)
    seed.py               best-effort starter profile
    config.py             reads ../config.yaml + ../deploy/state.env
    environments.py       Coder workspace lifecycle (env create/teardown/list)
    envs.yaml             environment linkage (gitignored; status read live from Coder)
    ../profiles/*.yaml    one YAML file per profile (local cache of the
                          S3-backed profile store)
```

The panel server (`main.py`, `frontend/`, `Dockerfile`, `run_local.sh`) was
removed. Infra values, mask profiles, neutralize defaults, and environment
launch settings ALL come from the repo's single
[`../config.yaml`](../config.yaml) via `backend/config.py` (with
[`../config.example.yaml`](../config.example.yaml) as the documented template).
No config duplication, nothing hardcoded.

## Masker knobs (env, honored by `masker/entrypoint.sh`)

The CLI passes these to the masker (same as the panel did); all overridable and
defaulting safely, so the masker also stays fully configurable when run outside
the CLI:

`SOURCE_DB_*` (the live source, parsed from the URL), `MASK_PROFILE`,
`GM_JOBS`, `NEUTRALIZE_MAIL`, `NEUTRALIZE_FETCHMAIL`, `NEUTRALIZE_PAYMENT`,
`NEUTRALIZE_SMTP_PARAM`, `RESET_ADMIN_LOGIN`, and `MASKED_DUMP_PUT_URL`
(presigned S3 PUT; when set, the masker `pg_dump`s the masked DB and uploads it
for download).

> Note: changes to `masker/entrypoint.sh` / `masker/profiles/` require
> rebuilding + pushing the masker image (`deploy/02_build_push.sh`) to take
> effect on real runs.
