# scripts/ — issue-driven env launcher

## issue_to_env.py

Entry point for the GitHub Actions hook in `.github/workflows/issue-env.yml`.
It runs on the **self-hosted `odoo-synth` runner** (the VM with the
`odoo-synth` CLI + `coder` + `awscli` installed).

Flow (one issue opened → one env + one agent run):

1. **Match preset from repo URL.** Normalize the issue's repo URL and match it
   against every profile's `addons_git_url` (SSH/HTTPS both normalize to
   `host/org/repo`). Pick the matching profile with a built image (`ready`).
   This is the same preset the Coder dashboard offers for that repo.
2. **Label the env.** Workspace name = `iss-<number>-<short-title-slug>`
   (e.g. `iss-42-fix-login-500`), so the env is labelled with the issue # + a
   short name on the Coder dashboard.
3. **Create the env** from the profile's latest successful **mask run** (masked
   dump in S3) via `environments.create(...)` → `coder create -t odoo-synth-env`.
   Passes `upgrade_modules` (the profile's discovered modules) so the
   post-launch `odoo-bin -u` reconciles the addon code schema against the
   masked source DB — **generic for any repo**, not hard-scoped to one.
4. **Wait** for the workspace build to reach `running`.
5. **Invoke the agent** inside the env via **ralph-wiggum** (baked into the
   golden AMI) driving **opencode** by default. The issue details are the task;
   the project system prompt (`agent-system-prompt.md`) + issue context are
   staged as `AGENT_CONTEXT.md` and (if the repo ships none) `AGENT.md` in the
   repo, so the agent *follows* the project context.

### Env vars

| var | meaning | default |
|---|---|---|
| `ISSUE_NUMBER` / `ISSUE_TITLE` / `ISSUE_BODY` / `ISSUE_URL` | issue payload | — |
| `ISSUE_REPO_URL` | addons repo URL to match a profile | — |
| `ODOO_SYNTH_AGENT` | agent ralph drives | `opencode` |
| `ODOO_SYNTH_MAX_ITER` | ralph autonomy cap | `15` |
| `ODOO_SYNTH_UPGRADE_MODULES` | override post-launch upgrade list | profile-discovered |
| `ODOO_SYNTH_BRANCH_HINT` | override addons branch | profile ref |
| `ODOO_SYNTH_WAIT_TIMEOUT` | seconds to wait for `running` | `1200` |
| `AWS_*` / `CODER_URL` / `CODER_SESSION_TOKEN` | env control plane | runner env / secrets |

### Exit codes

`0` env + agent launched · `1` no matching profile/dump · `2` env create failed ·
`3` env not running in time · `4` agent launch failed.

### Manual / CLI use

The same primitives are exposed on the CLI for ad-hoc use:

```bash
odoo-synth env create --profile-id <id> --source-run-id <run> \
  --issue "#42" --name iss-42-fix-login --upgrade-modules "module_a,module_b"
odoo-synth env wait <env_id> --timeout 1200
odoo-synth env agent <env_id> "Resolve #42: fix the login 500" --agent opencode --issue "#42"
```

See `.github/workflows/issue-env.yml` for the webhook wiring.
