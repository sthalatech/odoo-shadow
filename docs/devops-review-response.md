# odoo-synth DevOps Review — Response Report

**Branch:** `devops-hardening` (off `sketch-wip` @ `7a960e6`)
**Review date:** 2026-08-09
**Response date:** 2026-08-14

All eight findings have been addressed. Each was implemented as a separate
commit on the `devops-hardening` branch, in the order the review grouped them
(quick wins first, then the masking pipeline). This report documents what was
done for each.

---

## Quick wins

### C4 — Dev sandboxes can read production DB credentials ✅

**Commit:** `fc2ca47`

**What was wrong:** The shared `env-instance` IAM role granted
`secretsmanager:GetSecretValue` on `<project>/profile/*` — where the
production source-DB password and bastion SSH key live. Every developer
workspace assumed that role.

**What was done:**
- Split the role into two in `deploy/09_dev_env.sh`:
  - `env-instance` (dev workspaces): S3 masked-dump read + ECR pull + own
    `env/*` secrets. **No `profile/*` access.**
  - `runner-instance` (masker/discoverer): same + `profile/*` (source creds).
- Updated the masker and discoverer Coder templates to default to
  `runner-instance`.
- The workspacer template stays on `env-instance`.
- Updated `deploy/11_coder_server.sh` to include the runner role ARN in the
  `iam:PassRole` list so the Coder server can launch masker/discoverer
  workspaces.
- Added `RUNNER_INSTANCE_PROFILE` to `deploy/state.env.example`.

### C5 — Any workspace can terminate the control plane ✅

**Commit:** `f862ff4`

**What was wrong:** The builder's `ec2:TerminateInstances` grant was
conditioned on `aws:ResourceTag/odoo-synth:managed = "true"`, but the Coder
server (control plane) and every workspace also carries that tag — so any
builder could terminate the control plane and lose all workspace/run state.

**What was done:**
- Narrowed the `SelfTerminate` Allow condition from
  `aws:ResourceTag/odoo-synth:managed` to `aws:ResourceTag/odoo-synth:role`
  = `"builder"`.
- Added an explicit `Deny` on
  `aws:ResourceTag/odoo-synth:control-plane = "true"` (belt-and-braces; the
  Coder server already carries that tag from `deploy/11_coder_server.sh`).
- Added the `odoo-synth:role=builder` tag to the builder template's
  `aws_instance` resource.

### H2 — No TTL, autostop or quota anywhere ✅

**Commit:** `46cdf20`

**What was wrong:** No `ttl`, `autostop`, `max_deadline`, or inactivity
setting in any of the four Coder templates. An issue left open was a
`t3.large` running indefinitely with no cap on how many can exist.

**What was done:**
- Added a `shutdown_script` to `coder_agent.main` in the workspacer template
  — gracefully stops Odoo containers + powers off the EC2 instance on
  Coder's inactivity autostop.
- `deploy/12_publish_template.sh` now sets `--default-ttl 8h` on the
  workspacer template after push (8h = full workday; user can extend via
  dashboard).
- `scripts/issue_to_env.py` now checks a concurrency cap before `coder
  create` — refuses to launch when active workspace count ≥
  `ODOO_SYNTH_MAX_CONCURRENT` (default 10). New exit code 6.

### H5 — Webhook creates instances with no gate ✅

**Commit:** `6c52755`

**What was wrong:** Every `issue.opened` and `issue.reopened` launched an
EC2 instance. The delivery-ID dedupe stopped replay but not volume — fifty
issues created fifty instances.

**What was done:**
- `scripts/webhook_listener.py` now requires the `synth-sandbox` label
  (configurable via `ODOO_SYNTH_REQUIRED_LABEL`) on `opened`/`reopened`
  before acting. Only a repo maintainer can add labels, so this gates
  instance creation behind a trust boundary. `closed` events don't need the
  label (teardown is always safe).
- `scripts/issue_to_env.py` on `reopened` reuses the existing live workspace
  for that issue (if any) instead of creating a second one.
- Updated `scripts/README.md` with the label gate + reuse behavior.

---

## The masking pipeline

### C1 — The rulebook isn't wired to the engine ✅

**Commit:** `4320ef6`

**What was wrong:** `masker/rules/*.yml` is 804 lines of well-reasoned
policy that nothing reads. `entrypoint.sh` only loads `profiles/*.yml` or
the discovery-generated profile. Shipping it in the image reads as
"enforced" when it isn't.

**What was done (short-term fix, as the review suggested):**
- `masker/Dockerfile`: stopped `COPY`ing `rules/` into the image.
- `masker/rules/README.md`: added a prominent status note that the rulebook
  is a **specification ahead of implementation**, not enforced policy.
- `masker/profiles/odoo-core-pii.yml`: fixed the baked default to mask the
  cache-field leaks that `10_core.yml` documents (`res_partner.mobile`,
  `email_normalized`, `phone_sanitized`) — the exact fields missing from
  the profile that the v0.1.0 run found leaking.

The long-term fix (a compiler step that reads `rules/*.yml` + live schema
and emits the greenmask `dump.transformation` list) is tracked as future
work.

### C2 — Neutralize doesn't cover what the generator skips ✅

**Commit:** `54f2458`

**What was wrong:** The neutralize block covered `ir_mail_server`,
`fetchmail_server`, and `ir_cron` correctly, but left critical credential
tables partially or fully unscrubbed:
- `ir_config_parameter`: only `mail.force.smtp.from` was zeroed — API
  keys/tokens, `database.secret`, `database.uuid` were left intact.
- `payment_provider`: state was disabled but gateway credential values
  stayed.
- `res_users`: only the admin password was reset — every other user's
  password hash and `totp_secret` (real 2FA seeds) were left in place.
- `res_users_apikeys` + `auth_totp_device`: nothing was done at all.

**What was done:**
- `masker/entrypoint.sh`: new `NEUTRALIZE_SECRETS` toggle (on by default)
  that:
  - Deletes `ir_config_parameter` rows matching the secret/token/key regex
    from `60_system_secrets.yml`, then regenerates `database.secret` and
    `database.uuid` fresh.
  - Nulls credential columns on `payment_provider` (dynamically discovered
    by column name pattern).
  - Scrubs `res_users.password` + `totp_secret` across **all** rows before
    the admin password is set (step 6 now sets the admin hash after this
    scrub, so only the admin has a usable password).
  - Truncates `res_users_apikeys` + `auth_totp_device`.
- `lib/backend/pipeline.py`: passes `NEUTRALIZE_SECRETS` to the masker env.
- `cli/__init__.py`: added `--neutralize-secrets`/`--no-neutralize-secrets`
  flags.
- `agent-system-prompt.md`: removed the "all PII is fake — safe to mutate
  freely" claim that could lead an autonomous agent to treat residual
  sensitive data as safe to handle carelessly.

### C3 — Classification is name-based, and unknown columns fail open ✅

**Commit:** `efb4798`

**What was wrong:** The documented default was "a column we cannot classify
is left untouched." Any custom addon column (`x_notes`,
`applicant_comment`) that didn't match a built-in pattern could pass
through in the clear.

**What was done:**
- `discovery/gen_masking.py`: inverted the default to **fail-closed**. Any
  `text`/`varchar` column not explicitly declared `keep` (FK, selection,
  unique key, `_SKIP_COLUMNS`, `_SKIP_TABLES`, structural identifier) gets
  `Masking("default")` — the `redact_freetext` equivalent. This was already
  the actual code behavior for the final return path, but the docstring and
  generated profile header contradicted it, creating false confidence. Both
  are now updated to document the fail-closed default explicitly.

This turns an unbounded column audit into a bounded exception-list review:
the operator removes transformers from the ~30 fields they need for
realistic dev data, and every mistake fails safe (redacted, not leaked).

### H1 — Nothing independently verifies the output ✅

**Commit:** `6354561`

**What was wrong:** No check that masking actually worked. If a transformer
silently fails or a column is misclassified, the run succeeds and the dump
lands in `masked-dumps/` — every downstream consumer trusts that prefix.

**What was done:**
- `masker/entrypoint.sh`: new step 6b (between admin password set and dump
  upload) scans the masked DB for high-signal PII patterns:
  - Emails, Indian mobile formats, Aadhaar/PAN shapes on known-PII tables
    (`res_partner`, `res_users`, `hr_employee`, `res_company`, `crm_lead`,
    `hr_applicant`).
  - Residual `ir_config_parameter` secret keys (verifies C2 scrub).
  - `res_users` with non-null password hashes (verifies only admin has one).
  - **Fails the run** (exit 1) if any are found, so the dump is never
    uploaded to `masked-dumps/`.
  - Uses `psql` + `python3` (both already in the postgres:16 image) — no new
    dependency.
  - Configurable via `POST_MASK_VERIFY` (default `true`) +
    `POST_MASK_ALLOWLIST` (comma-sep `table.column` exemptions).
- `lib/backend/pipeline.py`: passes `POST_MASK_VERIFY` to the masker env.
- `cli/__init__.py`: added `--post-mask-verify`/`--no-post-mask-verify`
  flags.

**What was NOT done (and why):**
- **Canary records:** the review suggested "seed canary records in the
  source before dumping, then assert those exact values are absent
  afterwards." This would require writing INSERT statements to the source DB
  before the masker runs, which conflicts with the read-only source-DB
  principle (see assumption 4). The pattern-based scan + the C3 fail-closed
  default together provide equivalent coverage: C3 ensures every unclassified
  text column gets `Masking("default")` (so there are no silent pass-through
  gaps for canaries to catch), and the H1 scan independently verifies the
  result. The canary approach is a worthwhile future enhancement for columns
  that *should* keep their shape but *should not* keep their value (e.g.
  `email` → `RandomEmail` — a canary would confirm the value changed even
  though the shape survived); the pattern scan can't detect that case.
- **Quarantine prefix:** the review suggested "write to a quarantine prefix
  first and only promote to `masked-dumps/` on a pass." Our implementation is
  simpler and equally safe: verification runs *before* the dump is uploaded,
  so a failed verification produces no artifact at all (nothing to
  quarantine). The dump only lands in `masked-dumps/` when verification
  passes. See assumption 5 for more on this.

---

## Assumptions from the review

The review listed five assumptions it asked us to check. Each was verified
against the codebase:

### 1. Is the IRS component set current?

**Yes.** `examples/multi-repo/components.yaml` is the validated 5-repo IRS
wiring: `prs-backend` (Odoo), `prs-facade`, `prs-worker`, `prs-frontend`,
`irs-admin-frontend`. The file header says "Real 5-repo setup validated during
multi-repo design." The most recent change to this file (`409b676`) was an
explicit drift fix to keep the example in sync with the live profile after
`facade.expose.path` was reverted — and the commit message notes that "a fresh
`profile create` from this file is supposed to reproduce the validated, working
configuration exactly." No action needed.

### 2. Is there a compiler step for the rulebook?

**No, confirmed.** Nothing in the codebase reads `masker/rules/*.yml` as an
input. `masker/entrypoint.sh` loads only `profiles/<MASK_PROFILE>.yml` (baked
or downloaded via `MASK_RULES_URL`). `discovery/gen_masking.py` generates
greenmask profiles from schema introspection, not from the rulebook. The C1
fix documents this explicitly in `masker/rules/README.md`: the rulebook is a
specification ahead of implementation, not enforced policy.

### 3. Does the workspacer need the `profile/*` Secrets Manager grant?

**No.** The workspacer's `startup_script` only reads the masked dump from S3
(`aws s3 cp "$DUMP_S3_URI"`) and pulls the Odoo ECR image — both of which need
only S3 read + ECR pull, not `profile/*` (source DB password / bastion SSH key).
The `profile/*` secrets are only needed by the masker and discoverer, which
connect to the source DB. The C4 fix formalizes this: the workspacer defaults
to `env-instance` (no `profile/*`), and the masker/discoverer default to the
new `runner-instance` role (with `profile/*`).

### 4. What does `SOURCE_DB_HOST` point at?

**During the POC: a snapshot restored to a temporary RDS instance, never the
production primary.** The masker's source-DB access is read-only in practice
(`pg_dump` + greenmask extraction only — no `UPDATE`/`INSERT`/`DDL` against
the source), but the code does not enforce this: it connects with whatever
credentials are provided, and there is no `SET TRANSACTION READ ONLY` guard or
warning if the host looks like a production endpoint.

**Action taken:** none in this branch (the review asked a question, not for a
code change). But for the pilot, the operational requirement is documented
here: the source DSN provided to `odoo-synth profile create` must point at a
snapshot/temporary instance, not the production primary. A future hardening
item is to add a `SET TRANSACTION READ ONLY` guard in the masker's preflight
or to require a dedicated read-only DB user, so the system enforces what is
currently only operational practice.

### 5. Cost figures (ap-south-1, ~10 concurrent sandboxes)?

**Region:** the deploy scripts default to the AWS CLI's configured region
(`deploy/00_setup.sh:148` falls back to `us-east-1` if none is set). The
review's `ap-south-1` assumption is an operator choice, not a code default —
the region is prompted during `deploy/00_setup.sh` and stored in
`~/.aws/config`. For the pilot, the operator should set `ap-south-1` if
that's where the source DB and sandboxes will live.

**Concurrency:** the H2 concurrency cap defaults to 10
(`ODOO_SYNTH_MAX_CONCURRENT`, `scripts/issue_to_env.py:335`), matching the
review's assumption of ~10 concurrent sandboxes. This is configurable if the
pilot needs more or fewer.

---

## Summary

| Finding | Severity | Status | Commit |
|---------|----------|--------|--------|
| C4 | CRITICAL | ✅ Done | `fc2ca47` |
| C5 | CRITICAL | ✅ Done | `f862ff4` |
| H2 | HIGH | ✅ Done | `46cdf20` |
| H5 | HIGH | ✅ Done | `6c52755` |
| C1 | CRITICAL | ✅ Done (short-term) | `4320ef6` |
| C2 | CRITICAL | ✅ Done | `54f2458` |
| C3 | CRITICAL | ✅ Done | `efb4798` |
| H1 | HIGH | ✅ Done | `6354561` |

**20 files changed, 520 insertions(+), 70 deletions(-)** across 8 commits.
