# doppel: manifest-driven design

## The idea

Instead of code adapters with hardcoded assumptions (Postgres + greenmask,
Docker + Dockerfile), doppel is driven by a **manifest YAML** that describes
all four pipeline stages for any repo + any data source. Discovery
**auto-fills** the manifest by inspecting the GitHub repo files (Dockerfile,
docker-compose.yml, .env.sample, package.json, requirements.txt, go.mod,
etc.) and the source DB schema. The operator reviews/edits it. The tool
executes it.

The manifest is the contract — not a Python adapter class. No
technology is baked into the core. Postgres+greenmask+Docker is just what
the Odoo manifest happens to declare; a MySQL repo with a Makefile and a
buildpack is equally first-class.

## Why this is better than code adapters

| Code adapter (my earlier proposal) | Manifest (this design) |
|---|---|
| Writing a new app class = writing Python | Writing a new app class = editing YAML |
| The core imports adapter code → deployment coupling | The core reads YAML → zero code coupling |
| Adapters must be installed/registered | Manifests are self-describing files |
| Can't easily mix-and-match stages | Each stage is independently declarable |
| Discovery logic is per-adapter code | Discovery is generic file-pattern detection + manifest filling |

The adapter interface I proposed earlier isn't wrong — it's the wrong
*granularity*. Adapters make sense as **engine plugins** (a masking engine,
a build engine, a DB connector) — swappable implementations of a single
stage. But the *configuration* of which engines to use and how should live
in the manifest, not in code.

---

## The manifest

```yaml
# doppel.yaml — auto-discovered + human-edited.
# One per profile. Discovery fills what it can; the operator reviews + overrides.

# ─── source ───────────────────────────────────────────────────────────
# The production data source. Discovery detects the type from the DSN/URI
# scheme; the operator can override.
source:
  type: postgresql          # detected from postgresql:// DSN
  dsn: postgresql://...     # or { ref: env:SOURCE_DSN }
  ssh:
    enabled: false
    bastion: ""

# ─── components ───────────────────────────────────────────────────────
# Each component is one independently versioned repo. Discovery detects
# kind/build/ports/env from the repo files; the operator confirms.
components:
  - name: web
    repo_url: https://github.com/org/web
    repo_ref: main
    kind: docker            # detected: Dockerfile present
    build:
      engine: docker        # detected: Dockerfile
      dockerfile: Dockerfile  # detected
      context: .            # detected
      args:                 # filled from Dockerfile ARGs
        NODE_ENV: development
    run:
      # how the app starts inside the workspace
      command: ""           # empty = use the Dockerfile's CMD/ENTRYPOINT
      port: 3000            # detected from Dockerfile EXPOSE or compose
      readiness:
        check: http_get     # detected from port being HTTP-ish
        path: /
        timeout: 120s
    env:
      # discovered from .env.sample / .env.example / compose environment:
      keys:
        - DATABASE_URL      # → auto-wired to the masked DB
        - REDIS_URL         # → auto-wired to redis dependency
        - STRIPE_SECRET_KEY # → external (operator fills via Coder secret)
      from_repo: .env.sample  # auto-detected
    expose:
      port: 3000
      share: owner

  - name: worker
    repo_url: https://github.com/org/worker
    repo_ref: main
    kind: docker
    build:
      engine: docker
      dockerfile: Dockerfile
    run:
      command: ""
      port: null            # no HTTP surface — a background worker
    env:
      keys:
        - DATABASE_URL
        - REDIS_URL
        - CELERY_BROKER_URL

# ─── dependencies ─────────────────────────────────────────────────────
# Shared infra the components need. Discovery detects from compose + env keys;
# the operator confirms.
dependencies:
  - name: redis
    kind: redis            # detected from REDIS_URL / celery broker
    port: 6379
    expose: null            # internal-only

# ─── mask ─────────────────────────────────────────────────────────────
# How the source data is masked. Discovery snapshots the schema and generates
# a masking plan; the operator reviews/edits.
mask:
  engine: greenmask         # auto-selected: greenmask for postgres
  # The masking plan: auto-generated from schema introspection.
  # Tier 1 (generic, always present): column-name + data-type patterns.
  # Tier 2 (curated, adapter-provided): explicit table/column overrides.
  # Tier 3 (per-source, discovery-generated): the plan below.
  plan:
    # Auto-classified PII columns (from information_schema + name patterns)
    columns:
      - table: users
        column: email
        transformer: RandomEmail
      - table: users
        column: phone
        transformer: RandomE164PhoneNumber
      - table: users
        column: name
        transformer: Replace
        params: { value: "REDACTED" }
    # Tables to dump schema-only (no row data) — detected: low-row config tables
    exclude_table_data:
      - schema_migrations
      - ar_internal_metadata
    # Skip rules: columns/tables to never mask (detected: FK columns, unique
    # columns, enum-like columns)
    skip:
      - reason: foreign_key
      - reason: unique_constraint
      - reason: enum_like      # detected from small distinct-value count
  # Post-mask neutralization: arbitrary SQL the operator supplies or discovery
  # suggests based on detected framework (e.g. disable mail for Rails, disable
  # crons for Odoo). Generic — no framework assumptions in the core.
  post_mask_sql: |
    UPDATE users SET active = true;
    -- discovery may suggest framework-specific neutralization here
  # Dump slimming: prune old transactional rows. Discovery detects candidate
  # root tables (high row count + a date/timestamp column).
  subset:
    enabled: false
    days: 90
    roots:
      # auto-detected: high-volume tables with a created_at/write_date column
      orders: created_at
      events: created_at

# ─── build ────────────────────────────────────────────────────────────
# How each component's image is built. Per-component; declared above in
# components[].build but summarized here for the operator's review.
# The core just iterates components and executes build.engine.

# ─── environment ──────────────────────────────────────────────────────
# How the dev workspace boots. Discovery detects the app's start command
# from compose/Dockerfile/package.json scripts; the operator confirms.
environment:
  template: doppel-workspacer   # generic Coder template, reads this manifest
  data:
    restore:
      # How the masked data gets into the workspace's local DB.
      # Detected from source.type: pg_restore for postgres, mysql < for mysql, etc.
      engine: pg_restore
      dump_format: custom       # pg_dump -Fc
  startup:
    # The order components boot in (detected from compose depends_on / healthchecks)
    order: [redis, web, worker]
  readiness:
    # Wait for the primary web component before declaring "ready"
    primary: web
    check: http_get
    path: /
    timeout: 180s
```

---

## How discovery fills the manifest

Discovery is **generic file-pattern detection** — no framework knowledge
required. It inspects the repo at `repo_ref` and fills what it can:

### Repo file detection

| File detected | Manifest fields filled |
|---|---|
| `Dockerfile` | `kind: docker`, `build.engine: docker`, `build.dockerfile`, `run.port` (from EXPOSE), `build.args` (from ARG) |
| `docker-compose.yml` | `dependencies` (redis/postgres/etc services), `run.port`, `env.keys` (from `environment:` blocks), `startup.order` (from `depends_on`), `build.engine` per service |
| `.env.sample` / `.env.example` | `env.keys` + `env.from_repo` |
| `package.json` | `kind: process` (if no Dockerfile), `run.command` (from `scripts.start`/`scripts.dev`), `run.port` (from PORT env or common defaults) |
| `requirements.txt` / `pyproject.toml` | `kind: process` (if no Dockerfile), python deps for the build |
| `go.mod` | `kind: process`, `run.command: go run .` |
| `Cargo.toml` | `kind: process`, `run.command: cargo run` |
| `manage.py` | hints `kind: django` (framework detection, not required) |
| `Gemfile` + `Rakefile` | hints `kind: rails` |
| No build files at all | `kind: static` (static file serving) |

### Source DB detection

| DSN scheme | `source.type` | `mask.engine` | `data.restore.engine` |
|---|---|---|---|
| `postgresql://` | postgresql | greenmask | pg_restore |
| `postgres://` | postgresql | greenmask | pg_restore |
| `mysql://` | mysql | [mysql masking engine] | mysql restore |
| `mongodb://` | mongodb | [mongo masking engine] | mongorestore |
| (future) | ... | ... | ... |

### Schema introspection (generic, any DB)

Discovery snapshots the source schema and auto-generates the masking plan:

- **PII column detection**: column-name patterns (`*email*`, `*phone*`,
  `*name*`, `*address*`, `*ssn*`, `*tax*`, `*password*`, `*secret*`, `*token*`,
  `*api_key*`) + data-type heuristics (varchar/text in a PII-named column →
  redact). This is `gen_masking.py`'s existing logic, generalized beyond
  Odoo's `ir_model_fields`.
- **Skip detection**: FK columns (never mask), unique-constraint columns
  (never mask — already implemented), enum-like columns (small distinct-value
  count on a varchar → skip, since masking breaks code that does
  `{'status': 'active'}[row.status]`).
- **Subset root detection**: tables with high row count + a date/timestamp
  column → candidate `subset.roots`.
- **Schema-only table detection**: tables with < N rows and no PII columns →
  `exclude_table_data`.

### Framework hints (optional, not required)

Discovery can **optionally** detect the framework and suggest
framework-specific manifest additions — but these are *suggestions in the
manifest*, not hardcoded behavior:

| Detected | Suggestion added to manifest |
|---|---|
| `manage.py` + `settings.py` | `post_mask_sql`: disable Django mail, reset superuser |
| `Gemfile` + `config/database.yml` | `post_mask_sql`: disable Rails mail, clear secrets |
| `ir_module_module` table exists | Load the Odoo rulebook (the existing `masker/rules/`) |
| `__manifest__.py` files | Detect Odoo modules, python deps from manifests |

These are **curated suggestions the operator can accept or reject** — the
core never executes framework-specific logic directly. The Odoo rulebook
becomes a *contributed suggestion pack*, not a code dependency.

---

## Engine plugins (the right granularity for code)

The core executes the manifest by calling **engine plugins** — one per
stage implementation. These ARE code (Python), but they're swappable
implementations of a generic interface, not per-app adapters:

```
engines/
  mask/
    greenmask.py     # implements: dump + mask a postgres DB via greenmask
    mysql_mask.py    # implements: dump + mask a mysql DB (future)
  build/
    docker.py        # implements: docker build from a Dockerfile
    buildpack.py     # implements: pack build (future)
  restore/
    pg_restore.py    # implements: restore a pg_dump into local postgres
    mysql_restore.py # implements: restore a mysql dump (future)
  detect/
    repo_scan.py     # implements: inspect a repo for build/run/env files
    schema_scan.py   # implements: introspect a DB schema for masking
```

The manifest declares *which engine* to use per stage; the core loads it.
Adding a new DB type = writing one mask engine + one restore engine, not a
whole adapter. Adding a new build tool = writing one build engine.

This is the right split: **the manifest says WHAT, the engines say HOW.**

---

## The revised architecture

```
doppel/
├── core/                    ← manifest executor (generic, no app knowledge)
│   ├── manifest.py          ← load/validate/merge the doppel.yaml
│   ├── discover.py          ← generic repo + schema scan → fill manifest
│   ├── mask.py              ← read manifest.mask → call mask engine
│   ├── build.py             ← read manifest.components[].build → call build engine
│   ├── environment.py       ← read manifest.environment → launch Coder workspace
│   ├── pipeline.py          ← Coder runner lifecycle (generic)
│   ├── stores.py            ← profile/run/env stores (generic, from today)
│   └── config.py            ← config.yaml loader (generic, from today)
│
├── engines/                 ← swappable stage implementations
│   ├── mask/
│   │   └── greenmask.py
│   ├── build/
│   │   └── docker.py
│   ├── restore/
│   │   └── pg_restore.py
│   └── detect/
│       ├── repo_scan.py     ← file-pattern detection (Dockerfile, compose, .env, …)
│       └── schema_scan.py   ← DB-agnostic schema introspection
│
├── suggestions/             ← curated suggestion packs (optional, NOT required)
│   ├── odoo/                ← the Odoo rulebook + neutralize SQL + manifest template
│   │   ├── rules/           ← today's masker/rules/ (the PII field map)
│   │   ├── neutralize.sql   ← today's masker/entrypoint.sh neutralize steps
│   │   ├── subset_defaults.yml
│   │   └── manifest.yml     ← a pre-filled doppel.yaml for Odoo repos
│   ├── django/
│   │   ├── neutralize.sql
│   │   └── manifest.yml
│   └── rails/
│       └── manifest.yml
│
├── templates/
│   └── doppel-workspacer/   ← generic Coder template (reads the manifest,
│                               restores data, starts components, waits for readiness)
│
├── cli/doppel               ← the CLI
└── config.example.yaml      ← generic infra config (no app-specific keys)
```

### How the 4 stages work now

```
discover:
  1. core.discover.clone_repo(component)       # generic git clone
  2. engines.detect.repo_scan.scan(repo_dir)   # detect Dockerfile/compose/.env/…
  3. engines.detect.schema_scan.scan(source_db) # detect PII cols, skip cols, subset roots
  4. suggestions/<framework>/ suggest(applicable) # OPTIONAL: if framework detected,
                                                    # suggest neutralize SQL + rulebook
  5. core.discover.fill_manifest(...)           # merge all detections into doppel.yaml
  6. operator reviews/edits doppel.yaml

mask:
  1. core.mask.load_manifest()                  # read mask.engine + mask.plan
  2. engine = engines.mask[manifest.mask.engine] # e.g. greenmask
  3. engine.run(source, target, plan)            # mask the data
  4. engine.post_mask(target, manifest.mask.post_mask_sql) # neutralize

build:
  1. for each component:
  2.   engine = engines.build[component.build.engine]  # e.g. docker
  3.   engine.build(component.repo, component.build)    # build the image

environment:
  1. core.environment.launch(manifest)           # Coder workspace from template
  2. template reads manifest: restore data, start components in order, wait
     for readiness on the primary component
```

---

## What this means concretely

### For Odoo (today's user)

Nothing changes in capability. The Odoo suggestion pack provides:
- The full `masker/rules/` rulebook (Tier 2 curated masking)
- The neutralize SQL (today's `entrypoint.sh` steps, as SQL)
- The subset defaults (today's transactional table list)
- A pre-filled manifest template

Discovery detects `ir_module_module` → loads the Odoo suggestion pack →
fills the manifest with Odoo-specific values. The operator sees the same
behavior as today, just expressed as YAML instead of hardcoded Python.

### For a generic repo (the new user)

```bash
doppel profile create --source-dsn postgresql://prod... --repo https://github.com/org/app
doppel profile discover <id>
# → clones repo, finds Dockerfile + docker-compose.yml + .env.sample
# → detects postgres source, generates masking plan from schema
# → fills doppel.yaml: kind=docker, port=3000, env keys, redis dependency
# → suggests generic neutralization (disable crons if detected, etc.)
doppel profile show <id>    # operator reviews the manifest
$EDITOR profiles/<id>.yaml  # tweak masking, add post_mask_sql, etc.
doppel profile mask <id>    # masks the DB
doppel profile build <id>   # builds the image
doppel workspace create --profile-id <id>  # launches the dev environment
```

No adapter code written. No Python. Just a YAML that was auto-discovered
and human-edited.

### For a MySQL + Makefile repo (no Docker, no Postgres)

Discovery detects:
- `Makefile` → `build.engine: make`, `build.target: build`
- `mysql://` DSN → `source.type: mysql`, `mask.engine: mysql_mask`
- Schema scan → masking plan (same pattern logic, different DB)

The operator fills the gaps (no MySQL mask engine yet? they write one, or
use `mask.engine: custom` with a shell script). The core doesn't care.

---

## What stays from the current codebase

| Module | Becomes | Change |
|---|---|---|
| `lib/backend/config.py` | `core/config.py` | As-is |
| `lib/backend/profile_store.py` | `core/stores.py` (profile part) | As-is |
| `lib/backend/run_store.py` | `core/stores.py` (run part) | As-is |
| `lib/backend/env_store.py` | `core/stores.py` (env part) | As-is |
| `lib/backend/pipeline.py` (runner lifecycle) | `core/pipeline.py` | As-is (runner lifecycle is generic) |
| `lib/backend/environments.py` (Coder shim) | `core/environment.py` | Split: generic Coder shim stays; Odoo params come from manifest |
| `lib/backend/component_env.py` | `core/manifest.py` (env wiring part) | Generalized: reads manifest env keys instead of Odoo-specific wiring |
| `discovery/component_wiring.py` | `engines/detect/repo_scan.py` | Generalized: already detects compose/.env, extend to all file types |
| `discovery/gen_masking.py` (schema snapshot) | `engines/detect/schema_scan.py` | Generalized: strip Odoo selection detection, keep column pattern logic |
| `masker/entrypoint.sh` (greenmask dump/restore) | `engines/mask/greenmask.py` | Extract the generic dump/mask/restore core |
| `masker/rules/` | `suggestions/odoo/rules/` | Move to suggestion pack |
| `masker/entrypoint.sh` (neutralize SQL) | `suggestions/odoo/neutralize.sql` | Extract SQL from the bash script |
| `odoo/Dockerfile` | `suggestions/odoo/build/Dockerfile` | Move to suggestion pack |
| `coder/templates/odoo-synth-workspacer/` | `templates/doppel-workspacer/` | Generalize: reads manifest instead of hardcoded Odoo boot |

---

## The design philosophy

1. **The manifest is the contract.** Every stage reads from it. Nothing is
   hardcoded about what DB, what build tool, or what framework.
2. **Discovery fills, the operator decides.** The tool never guesses
   silently — it proposes, the human reviews. The manifest is always
   human-readable and human-editable.
3. **Engines are swappable implementations, not app adapters.** Adding a
   new DB type = one mask engine + one restore engine. Adding a new build
   tool = one build engine. No "Django adapter" or "Rails adapter" needed
   unless you want curated suggestions.
4. **Suggestion packs are optional, not required.** The Odoo rulebook makes
   Odoo masking better, but the tool works without it. A new framework
   starts with generic detection and adds a suggestion pack when someone
   cares enough to curate one.
5. **No technology is privileged.** Postgres is not special. Docker is not
   special. They're just what the first manifest happened to declare.
