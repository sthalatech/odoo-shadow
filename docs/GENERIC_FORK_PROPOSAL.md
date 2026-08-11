# Proposal: Forking odoo-synth into a generic repo-synth

## TL;DR

odoo-synth is a **pipeline** (profile → discover → mask → build → environment)
with four deeply Odoo-coupled layers and a **generic skeleton already present**
(the `kind: docker/process/static` component support). The fork re-centers the
pipeline on that generic skeleton and demotes Odoo to **one adapter plugin**
among many, rather than rewriting from scratch.

The result: a tool that takes *any* production database + *any* repo, masks
the PII, builds a provenance-pinned image, and launches isolated Coder dev
environments seeded from the masked dump — with per-technology adapters
providing the domain-specific knowledge Odoo currently hardcodes.

---

## 1. Where the Odoo coupling actually lives

After a full read of the codebase, the Odoo-specific assumptions concentrate
in **four layers**. Everything else (S3 state, Coder workspace lifecycle,
secret management, run/profile stores, the CLI, config loading) is already
generic infra orchestration.

### 1a. Discovery (`discovery/discover.py`, `discovery/gen_masking.py`)

The most Odoo-entangled layer. It:

- Reads `ir_module_module` to detect the Odoo **series** and **installed
  modules** (Odoo's module registry table — meaningless outside Odoo).
- Scans `__manifest__.py` files (Odoo's addon manifest format) for
  `external_dependencies.python/bin`.
- Has a hardcoded `_ODOO_PROVIDED` import set and `_CORE_CONFIG_KEYS` set.
- Detects Odoo **selection fields** via `ir_model_fields.ttype='selection'`
  (so masking doesn't destroy Odoo's fixed-vocabulary enum columns).
- Reads `odoo.tools.config['key']` access patterns to find source-specific
  `odoo.conf` keys.
- `gen_masking.py` generates a greenmask profile by introspecting the live
  schema, but its PII classification heuristics and skip-lists are Odoo-shaped
  (it knows `res_partner` is a person table, `ir_*` tables are config, etc.).

### 1b. Masking (`masker/rules/`, `masker/entrypoint.sh`, `masker/greenmask.tmpl.yml`)

- `masker/rules/*.yml` — the **community rulebook**: 11 YAML files mapping
  Odoo models/fields to masking strategies. This is the curated, reviewed
  knowledge of *which Odoo fields are sensitive*. It is Odoo's single biggest
  domain contribution and the hardest to generalize.
- `masker/entrypoint.sh` — the masking runtime. The **greenmask dump/restore**
  core is generic (dump source → mask → restore into target → pg_dump). But:
  - **Neutralize steps** hit Odoo tables: `ir_mail_server`,
    `fetchmail_server`, `payment_provider`, `ir_cron`, `ir_config_parameter`.
  - **Admin password reset** writes a pbkdf2_sha512 hash to `res_users` via
    `ir_model_data`.
  - **Subset-plan defaults** are Odoo transactional tables (`sale_order`,
    `account_move`, `stock_picking`, …).
  - **Product-name randomization** writes to `product_template`.
- `masker/greenmask.tmpl.yml` — the baked fallback profile masks specific
  Odoo columns (`res_partner.name`, `res_users.login`, etc.).

### 1c. Build (`lib/backend/build.py`, `odoo/Dockerfile`)

- `odoo/Dockerfile` is entirely Odoo-specific: `FROM odoo:17`, clones Odoo
  source at a pinned ref, unzips enterprise addons, copies custom addons,
  installs manifest-discovered pip deps.
- `run_build()` **requires** an `odoo` component and calls
  `_run_odoo_build()` first, then handles non-odoo components as an
  afterthought.
- Enterprise-zip handling (`odoo/enterprise.zip`) is Odoo-only.

### 1d. Environments (`coder/templates/odoo-synth-workspacer/`, `lib/backend/environments.py`)

- The workspacer Terraform template's **startup_script** boots Odoo: restores
  the dump into a local Postgres, pulls the ECR image, bind-mounts addons,
  writes `odoo.conf`, resets admin password, waits for Odoo to answer HTTP.
- `environments.create()` passes Odoo-specific params: `odoo_image`,
  `odoo_master_password`, `odoo_conf_extra_b64`, `db_name=odoo`.
- The agent system prompt (`agent-system-prompt.md`) is Odoo-flavored.
- The "expose" / app-tile logic references `127.0.0.1:8069` (Odoo's port).

### 1e. Profiles + config (lighter coupling)

- `profiles.py`: `KNOWN_COMPONENT_KINDS = ("odoo", "docker", "process",
  "static")` — `odoo` is a first-class kind with flat legacy fields
  (`odoo_series`, `odoo_git_url`, `needs_enterprise`).
- `config.example.yaml`: `odoo.git_ref`, `addons.*`, Odoo password fields.
- `pipeline._mask_env_pairs()`: emits `ODOO_ADMIN_PASSWORD`, `RESET_ADMIN_LOGIN`,
  Odoo-specific neutralize flags.

---

## 2. What's already generic (don't touch)

These modules are Odoo-agnostic and should be lifted into the fork **as-is**:

| Module | Why it's generic |
|--------|-----------------|
| `lib/backend/config.py` | Reads `config.yaml` + `state.env`, resolves `ref:env/ssm` secrets. No Odoo logic. |
| `lib/backend/yamlconfig.py` | YAML→env dict loader. Fully generic. |
| `lib/backend/profile_store.py` | One YAML per profile, mirrored to S3. No Odoo assumptions. |
| `lib/backend/run_store.py` | S3-backed runs + logs. Generic. |
| `lib/backend/env_store.py` | `envs.yaml` env linkage. Generic. |
| `lib/backend/store.py` | Thin facade over the three stores. Generic. |
| `lib/backend/pipeline.py` | Coder runner workspace orchestration (upload env-file, presign result, launch, tail logs, poll). The **runner lifecycle** is generic; only `_mask_env_pairs()` and `parse_dsn` (postgres-only) are Odoo-flavored. |
| `lib/backend/environments.py` | Coder workspace lifecycle (create/list/delete/reconcile, ssh_exec, run_agent). The **Coder shim** is generic; only `create()`'s param list is Odoo-specific. |
| `lib/backend/component_env.py` | Multi-component env wiring. Already generic (designed for docker/process/static). |
| `discovery/component_wiring.py` | Env-sample classification for non-odoo components. Already generic. |
| `cli/odoo-synth` | argparse CLI shell. Rename + rebrand, but the command structure (profile/run/workspace/config) is generic. |
| `deploy/*.sh` | Infra provisioning (ECR, Coder server, AMI baking, templates). Mostly generic; the Odoo image bake in `02_build_push.sh` is the exception. |

---

## 3. The fork architecture: adapter plugins

### Core principle

Replace the Odoo-specific code paths with a **plugin/adapter interface**.
Each adapter knows how to discover, build, mask, and boot one class of
application. Odoo becomes `adapters/odoo/` — the first adapter, not the core.

```
repo-synth/                        (the fork)
├── core/                          ← generic pipeline (from lib/backend/)
│   ├── config.py                  (as-is)
│   ├── profile_store.py           (as-is)
│   ├── run_store.py               (as-is)
│   ├── env_store.py               (as-is)
│   ├── pipeline.py                (generic runner lifecycle; mask env pairs
│   │                                delegated to adapter)
│   ├── environments.py            (generic Coder shim; template name +
│   │                                boot params from adapter)
│   ├── build.py                   (generic: iterate components, call
│   │                                adapter.build() per component)
│   ├── discovery.py               (generic: call adapter.discover())
│   ├── profiles.py                (generic components; no "odoo" kind
│   │                                hardcoded — kinds come from adapters)
│   └── adapter.py                 ← THE interface
│
├── adapters/
│   ├── odoo/                      ← the first adapter (extracted from today's code)
│   │   ├── discover.py            (today's discovery/discover.py)
│   │   ├── gen_masking.py         (today's discovery/gen_masking.py)
│   │   ├── masker/
│   │   │   ├── entrypoint.sh      (today's masker/entrypoint.sh)
│   │   │   ├── rules/             (today's masker/rules/ — the rulebook)
│   │   │   └── greenmask.tmpl.yml
│   │   ├── build/                 (today's odoo/Dockerfile + build context)
│   │   ├── workspace/             (today's coder/templates/odoo-synth-workspacer/)
│   │   └── adapter.py             ← implements the interface for Odoo
│   │
│   ├── django/                    ← future adapter example
│   ├── rails/                     ← future
│   └── generic-docker/            ← the no-app-framework default:
│       └── (just builds the repo's own Dockerfile, generic masking)
│
├── cli/repo-synth                 (renamed CLI)
├── deploy/                        (generic infra; per-adapter image builds
│                                   become adapter-supplied build contexts)
└── config.example.yaml            (adapter-agnostic; adapter config is
                                    nested under adapters.<name>)
```

### The adapter interface

```python
# core/adapter.py — the contract every adapter implements

class Adapter:
    """One per class of application (Odoo, Django, Rails, generic-docker).

    An adapter provides the domain-specific knowledge the generic pipeline
    needs for four stages: discover, build, mask, and environment boot."""

    # Declared component kinds this adapter owns (e.g. "odoo", "django",
    # "docker"). The profile's components reference these; the core
    # validates them against registered adapters instead of a hardcoded tuple.
    kinds: tuple[str, ...]

    # --- Discovery ---

    def discover(self, profile, component, source_conn, emit) -> dict:
        """Inspect the live source DB + the component's repo to produce a
        discovery result (installed modules, python deps, masking plan,
        subset plan, config keys, etc.). Runs inside a discovery runner
        workspace. Returns a JSON-serializable dict the core folds into the
        profile."""

    def discovery_image(self) -> str:
        """The ECR image URI for this adapter's discovery container."""

    def discovery_env(self, profile, component, source_conn, put_url) -> list[tuple[str, str]]:
        """Env pairs for the discovery runner workspace."""

    # --- Build ---

    def build(self, profile, component, discovery_result, emit) -> dict:
        """Build a provenance-pinned image for this component. Returns
        {exit_code, image_uri, resolved_ref, error}."""

    def build_context(self, component, include_extras) -> bytes:
        """The tarball the builder workspace downloads + builds. For Odoo
        this is odoo/ + enterprise.zip; for generic-docker it's the repo
        itself (or empty — the builder clones the repo)."""

    def base_image(self, component) -> str:
        """The FROM image for the build (odoo:17, python:3.12, etc.)."""

    # --- Mask ---

    def mask_env(self, src, tgt, params, mask_rules_url, subset_plan_url) -> list[tuple[str, str]]:
        """Env pairs for the masker runner workspace. The generic
        SOURCE_DB_*/TARGET_DB_* pairs are added by the core; the adapter
        adds only its domain-specific knobs (neutralize flags, admin
        password, etc.)."""

    def masker_image(self) -> str:
        """The ECR image URI for this adapter's masker container."""

    def default_masking_profile(self) -> str:
        """The baked fallback greenmask YAML (adapter-specific rulebook)."""

    def default_subset_roots(self) -> dict[str, str]:
        """Default {table: date_column} for dump slimming."""

    # --- Environment ---

    def workspace_template(self) -> str:
        """The Coder template name for dev environments (e.g.
        'repo-synth-odoo-workspacer')."""

    def workspace_params(self, profile, component, env_settings) -> list[tuple[str, str]]:
        """Template parameters for workspace create (image, dump uri, repo
        url, app-specific params like odoo_conf_extra). The core adds the
        generic infra params (ami, subnet, sg, instance_profile, region)."""

    def app_url_slug(self) -> str:
        """The coder_app slug for the primary web UI (e.g. 'odoo')."""
```

### How the core calls adapters

The four pipeline stages change from Odoo-hardcoded to adapter-delegated:

```
discover:   core.discovery.run_discovery(profile)
              → find the profile's primary component's kind
              → look up the registered adapter for that kind
              → adapter.discover_env(...) + adapter.discovery_image()
              → pipeline.run_runner(adapter.discovery_image(), env, ...)
              → fold adapter's result dict into the profile

build:      core.build.run_build(profile)
              → for each component:
                  adapter = registry.get(component.kind)
                  adapter.build(profile, component, discovery, emit)
              (no more "must have odoo component" requirement)

mask:       core.pipeline.run_operation("mask", params)
              → adapter = registry.get(profile.primary_kind)
              → generic env pairs (SOURCE_DB_*, TARGET_DB_*, SSH_*)
              → adapter.mask_env(...) for domain-specific pairs
              → pipeline.run_runner(adapter.masker_image(), env, ...)

env:        core.environments.create(profile)
              → adapter = registry.get(profile.primary_kind)
              → generic infra params (ami, subnet, sg, ...)
              → adapter.workspace_params(...) for app-specific params
              → coder create -t adapter.workspace_template()
```

---

## 4. The masking generalization problem (the hard part)

The masking layer is where the most domain knowledge lives, and where a
generic tool needs the most care. Three tiers of generality:

### Tier 1: Generic schema-driven masking (always available)

`gen_masking.py` already introspects `information_schema.columns` and assigns
greenmask transformers by **column shape + name pattern**. This works on ANY
Postgres database. Generalize it:

- **Column-name patterns** (`*_email`, `*_phone`, `*name*`, `*_address_*`,
  `*_ssn`, `*_tax_id`, …) → assign transformers by pattern, not by Odoo model.
- **Data-type heuristics** (varchar in a column named like PII → redact;
  FK column → never mask; unique column → never mask [already implemented]).
- **Skip heuristics**: config/metadata tables (low row count, no PII shape).
  Today this is Odoo's `ir_*` prefix; generalize to "tables with < N rows and
  no PII-shaped columns are schema-only (exclude_table_data)."

This gives every adapter a **reasonable default** masking plan with zero
domain knowledge. It won't be as good as a curated rulebook, but it's safe
(the worst case is over-masking, not leaking PII).

### Tier 2: Adapter-provided rulebook (the Odoo model)

Each adapter ships a `rules/` directory like today's `masker/rules/` — a
curated, reviewed mapping of *which fields are sensitive* for that
application. The adapter's `default_masking_profile()` returns this. For
Odoo, this is the existing 11-file rulebook, unchanged.

### Tier 3: Per-source discovery-generated plan (already implemented)

`gen_masking.py` generates a per-source plan during discovery, which the
operator can review/edit. This is adapter-owned: the Odoo adapter's version
knows Odoo selection fields; a Django adapter's version would know Django's
auth_user table, etc.

**The key design decision**: the generic core provides Tier 1 as a fallback;
each adapter layers Tier 2 + Tier 3 on top. A new adapter (Django, Rails)
starts with Tier 1 (safe, generic) and gradually builds a Tier 2 rulebook.

---

## 5. The "generic-docker" adapter (the no-framework default)

This is what makes the tool work with **any repo** out of the box, before
anyone writes a domain adapter:

- **discover**: clone the repo, scan `requirements.txt` / `package.json` /
  `go.mod` / `Cargo.toml` / `pom.xml` for dependencies. No DB introspection
  beyond the generic schema snapshot for masking.
- **build**: `docker build` the repo's own Dockerfile. No special build
  context — the builder clones the repo directly (today's
  `build_mode=generic` path, already implemented).
- **mask**: Tier-1 generic schema-driven masking. No neutralize steps
  (there's no app framework to neutralize). Optional `--post-mask-sql` hook
  for the operator to supply custom neutralization.
- **environment**: a generic workspace template that restores the dump into
  local Postgres + runs `docker compose up` (or the repo's own start script).
  Exposes whatever port the Dockerfile declares.

This adapter alone covers "I have a repo with a Dockerfile and a Postgres
DB — give me a masked dev environment." That's the 80% case.

---

## 6. Concrete migration steps (in priority order)

### Phase 1: Extract the adapter interface (no behavior change)

1. Create `core/adapter.py` with the `Adapter` ABC.
2. Create `adapters/odoo/adapter.py` implementing it by delegating to today's
   code (thin wrappers — no logic moved yet).
3. Create `core/registry.py` — a dict of `kind → Adapter` populated at
   import time. Odoo registers itself.
4. Replace `KNOWN_COMPONENT_KINDS` in `profiles.py` with
   `registry.kinds()`.
5. **Test**: everything still works, Odoo is now reached via the registry
   instead of hardcoded conditionals.

### Phase 2: Generalize the four pipeline stages

6. `discovery.py`: replace the Odoo-specific env-pair builder with
   `adapter.discovery_env()`. The runner-workspace launch + S3 polling
   stays in the core.
7. `build.py`: replace `_run_odoo_build` + `_run_generic_docker_build` with
   `adapter.build()` per component. Remove the "must have odoo component"
   requirement — the primary component is whatever the profile declares.
8. `pipeline.py`: split `_mask_env_pairs` into generic pairs (core) +
   `adapter.mask_env()` (domain). The masker image URI comes from the adapter.
9. `environments.py`: split `create()`'s param list into generic infra
   params (core) + `adapter.workspace_params()` (domain). The template name
   comes from the adapter.
10. **Test**: Odoo still works through the adapter; the generic-docker path
    works with no Odoo code loaded.

### Phase 3: Implement the generic-docker adapter

11. `adapters/generic-docker/adapter.py`: uses Tier-1 schema-driven masking,
    the repo's own Dockerfile for builds, a generic docker-compose workspace
    template.
12. Extract `gen_masking.py`'s schema-snapshot + pattern-matching into
    `core/masking.py` (generic), with the Odoo-specific selection-field
    detection staying in the Odoo adapter.
13. **Test**: point at a non-Odoo repo with a Postgres DB → get a masked dev
    environment.

### Phase 4: Rebrand + cleanup

14. Rename `cli/odoo-synth` → `cli/repo-synth` (or whatever name).
15. Rename Coder templates: `odoo-synth-*` → `repo-synth-*` (with
    `repo-synth-odoo-*` for the Odoo adapter's templates).
16. Generalize `config.example.yaml`: remove `odoo.*` top-level keys; move
    Odoo config under `adapters.odoo.*`.
17. Generalize `deploy/02_build_push.sh`: the base-image bake becomes
    per-adapter (Odoo adapter bakes its odoo base; generic-docker needs none).
18. Rename the project, update README, commit.

### Phase 5 (ongoing): more adapters

19. `adapters/django/` — knows `auth_user`, `django_session`, Django settings
    neutralization, `manage.py` boot.
20. `adapters/rails/` — knows `users`, `active_sessions`, Rails credentials,
    `rails server` boot.
21. Each adapter contributes its own `rules/` rulebook over time.

---

## 7. What stays, what moves, what's deleted

| Today | Fork | Action |
|-------|------|--------|
| `lib/backend/config.py` | `core/config.py` | Move as-is |
| `lib/backend/profile_store.py` | `core/profile_store.py` | Move as-is |
| `lib/backend/run_store.py` | `core/run_store.py` | Move as-is |
| `lib/backend/env_store.py` | `core/env_store.py` | Move as-is |
| `lib/backend/store.py` | `core/store.py` | Move as-is |
| `lib/backend/yamlconfig.py` | `core/yamlconfig.py` | Move as-is |
| `lib/backend/component_env.py` | `core/component_env.py` | Move as-is |
| `discovery/component_wiring.py` | `core/component_wiring.py` | Move as-is |
| `lib/backend/pipeline.py` | `core/pipeline.py` | Move; split `_mask_env_pairs` |
| `lib/backend/environments.py` | `core/environments.py` | Move; split `create()` params |
| `lib/backend/build.py` | `core/build.py` | Move; generalize `run_build` |
| `lib/backend/discovery.py` | `core/discovery.py` | Move; delegate env to adapter |
| `lib/backend/profiles.py` | `core/profiles.py` | Move; kinds from registry |
| `lib/backend/seed.py` | `core/seed.py` | Move; generalize starter profile |
| `discovery/discover.py` | `adapters/odoo/discover.py` | Move to adapter |
| `discovery/gen_masking.py` | `adapters/odoo/gen_masking.py` + `core/masking.py` | Split: generic schema snapshot → core; Odoo selection detection → adapter |
| `masker/` | `adapters/odoo/masker/` | Move to adapter |
| `odoo/Dockerfile` | `adapters/odoo/build/Dockerfile` | Move to adapter |
| `coder/templates/odoo-synth-workspacer/` | `adapters/odoo/workspace/` | Move to adapter |
| `coder/templates/odoo-synth-builder/` | `core/builder/` (generic) + adapter build context | Generalize: `build_mode=generic` is the default; Odoo build is adapter-supplied |
| `coder/templates/odoo-synth-discoverer/` | `core/discoverer/` (generic runner) | Generalize: the runner template is generic; the discovery image is adapter-supplied |
| `coder/templates/odoo-synth-masker/` | `core/masker-runner/` (generic runner) | Generalize: the runner template is generic; the masker image is adapter-supplied |
| `config.example.yaml` `odoo.*` keys | `adapters.odoo.*` | Nest under adapters |
| `KNOWN_COMPONENT_KINDS` hardcoded | `registry.kinds()` | Dynamic |
| `_ODOO_PROVIDED`, `_CORE_CONFIG_KEYS` | `adapters/odoo/` | Move to adapter |

---

## 8. The naming question

`odoo-synth` → suggestions:

- **`repo-synth`** — minimal rebrand, keeps the "synth" identity (synthesizing
  dev environments from production data).
- **`devmask`** — emphasizes the masking → dev-env flow.
- **`provenance`** — emphasizes the build-pinning guarantee.
- **`dumpsite`** — informal, memorable.
- **`maskforge`** — masking + building.

I'd go with **`repo-synth`** for the fork — it's the smallest cognitive leap
from `odoo-synth` and accurately describes the general case.

---

## 9. Risk assessment

**Low risk** (the core orchestration is already generic):
- Profile/run/env stores, config loading, Coder shim, S3 state, CLI structure.
- The generic-docker build path (`build_mode=generic`) is already implemented
  and tested.

**Medium risk** (needs careful extraction):
- Splitting `pipeline._mask_env_pairs` and `environments.create()` into
  generic + adapter parts without breaking the Odoo flow.
- Generalizing `gen_masking.py` — the schema snapshot is generic, but the
  selection-field detection and skip-tables heuristics are Odoo-shaped.

**High risk** (the real work):
- The **masking rulebook**. Today's `masker/rules/` is a curated, reviewed,
  darkstore-validated map of Odoo PII fields. A generic tool's Tier-1
  schema-driven masking will be *safe* (won't leak PII) but *coarse*
  (may over-mask or miss app-specific sensitive fields). Each new adapter
  needs its own rulebook to be truly useful. This is an ongoing community
  effort, not a one-time port.
- The **workspace template**. Odoo's boot sequence (dump restore → image pull
  → addons mount → odoo.conf → admin reset → HTTP readiness check) is
  intricate. A generic docker-compose workspace is simpler but less polished.
  The generic-docker adapter's template is new code.

**Not a risk** (already solved):
- Multi-component/multi-repo profiles — the component model is already
  generic. An adapter just handles its own kind; the core iterates.
- Coder workspace lifecycle — fully generic already.
- Secret management — Secrets Manager + Coder user secrets, no Odoo coupling.
