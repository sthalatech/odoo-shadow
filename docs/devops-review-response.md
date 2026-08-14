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

---

## Assumptions from the review

The review listed five assumptions it asked us to check. Responses:

1. **Is the IRS component set current?** — Yes, `examples/multi-repo/components.yaml`
   is the current IRS wiring.
2. **Is there a compiler step for the rulebook?** — No, confirmed. The
   rulebook is a spec ahead of implementation (C1 fix documents this
   explicitly now).
3. **Does the workspacer need the `profile/*` Secrets Manager grant?** — No.
   Confirmed by the C4 fix: the workspacer only needs masked-dump read +
   ECR pull + its own `env/*` secrets.
4. **What does `SOURCE_DB_HOST` point at?** — During the POC, a snapshot
   restored to a temporary instance, never the production primary.
5. **Cost figures (ap-south-1, ~10 concurrent sandboxes)?** — The H2
   concurrency cap defaults to 10, matching the review's assumption.

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
