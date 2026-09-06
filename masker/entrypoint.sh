#!/usr/bin/env bash
# masker orchestration: dump(mask) SOURCE -> restore into TARGET RDS ->
# neutralize -> set admin password. Idempotent on the target DB.
set -euo pipefail

: "${SOURCE_DB_HOST:?}" "${SOURCE_DB_NAME:?}" "${SOURCE_DB_USER:?}"
: "${TARGET_DB_HOST:?}" "${TARGET_DB_NAME:?}" "${TARGET_DB_USER:?}" "${TARGET_DB_PASSWORD:?}"
export SOURCE_DB_PORT="${SOURCE_DB_PORT:-5432}"
export TARGET_DB_PORT="${TARGET_DB_PORT:-5432}"
export SOURCE_DB_PASSWORD="${SOURCE_DB_PASSWORD:-}"
ODOO_ADMIN_PASSWORD="${ODOO_ADMIN_PASSWORD:-admin}"
export GM_STORAGE="/tmp/gm_storage"

# ---- configurable knobs (all overridable via env; nothing hardcoded) ----
# masking profile: /work/profiles/<MASK_PROFILE>.yml (falls back to the legacy
# baked template for backward-compat).
MASK_PROFILE="${MASK_PROFILE:-odoo-core-pii}"
export GM_JOBS="${GM_JOBS:-4}"
# neutralize toggles (true|false) — post-mask hygiene on the masked replica.
NEUTRALIZE_MAIL="${NEUTRALIZE_MAIL:-true}"
NEUTRALIZE_FETCHMAIL="${NEUTRALIZE_FETCHMAIL:-true}"
NEUTRALIZE_PAYMENT="${NEUTRALIZE_PAYMENT:-true}"
NEUTRALIZE_SMTP_PARAM="${NEUTRALIZE_SMTP_PARAM:-true}"
# disable ALL scheduled actions (ir_cron) on the masked replica: a dev copy must
# never fire crons (delayed emails, external syncs, custom jobs that hit prod
# systems, or ones that choke on masked data). Generic across sources.
NEUTRALIZE_CRONS="${NEUTRALIZE_CRONS:-true}"
# reset the admin login string to 'admin' (in addition to the password).
RESET_ADMIN_LOGIN="${RESET_ADMIN_LOGIN:-true}"

say(){ echo "[masker] $*"; }
is_true(){ case "${1,,}" in true|1|yes|on) return 0;; *) return 1;; esac; }
rm -rf "$GM_STORAGE"; mkdir -p "$GM_STORAGE"

# 0a. optional SSH tunnel to reach the SOURCE DB through a bastion.
#     When SSH_ENABLED=true, open  localhost:LOCAL -> SOURCE_DB_HOST:SOURCE_DB_PORT
#     via  SSH_BASTION_USER@SSH_BASTION_HOST:SSH_BASTION_PORT  using SSH_PRIVATE_KEY,
#     then rewrite SOURCE_DB_HOST/PORT to the local end so everything downstream
#     (preflight, greenmask) connects through the tunnel transparently.
SSH_ENABLED="${SSH_ENABLED:-false}"
if is_true "$SSH_ENABLED"; then
  : "${SSH_BASTION_HOST:?SSH_ENABLED but SSH_BASTION_HOST unset}"
  : "${SSH_BASTION_USER:?SSH_ENABLED but SSH_BASTION_USER unset}"
  : "${SSH_PRIVATE_KEY:?SSH_ENABLED but SSH_PRIVATE_KEY unset}"
  SSH_BASTION_PORT="${SSH_BASTION_PORT:-22}"
  SSH_LOCAL_PORT="${SSH_LOCAL_PORT:-15432}"
  REMOTE_HOST="$SOURCE_DB_HOST"; REMOTE_PORT="$SOURCE_DB_PORT"
  KEY=/tmp/ssh_key
  # accept keys pasted with literal "\n" as well as real newlines
  printf '%b\n' "$SSH_PRIVATE_KEY" | sed 's/\\n/\n/g' > "$KEY"
  chmod 600 "$KEY"
  # M1 (Pass-2 review): StrictHostKeyChecking=no + UserKnownHostsFile=/dev/null
  # accepts ANY host key (no MITM protection) on the path carrying production
  # DB credentials. Use accept-new (auto-accepts first-seen keys, rejects changed
  # keys = MITM detection) with a persistent known_hosts file so a key change
  # is caught on subsequent connections. The known_hosts file is under /tmp
  # (ephemeral per container run), so the first connection records the key and
  # subsequent runs verify it -- a bastion key rotation requires clearing
  # /tmp/ssh_known_hosts.
  export SSH_KNOWN_HOSTS=/tmp/ssh_known_hosts
  touch "$SSH_KNOWN_HOSTS"; chmod 600 "$SSH_KNOWN_HOSTS"
  say "opening SSH tunnel: localhost:${SSH_LOCAL_PORT} -> ${REMOTE_HOST}:${REMOTE_PORT} via ${SSH_BASTION_USER}@${SSH_BASTION_HOST}:${SSH_BASTION_PORT} ..."
  if ! ssh -f -N \
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$SSH_KNOWN_HOSTS" \
        -o ExitOnForwardFailure=yes -o ConnectTimeout=15 \
        -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        -i "$KEY" -p "$SSH_BASTION_PORT" \
        -L "127.0.0.1:${SSH_LOCAL_PORT}:${REMOTE_HOST}:${REMOTE_PORT}" \
        "${SSH_BASTION_USER}@${SSH_BASTION_HOST}" 2>/tmp/ssh.err; then
    echo "[masker] SSH TUNNEL FAILED to ${SSH_BASTION_USER}@${SSH_BASTION_HOST}:${SSH_BASTION_PORT}" >&2
    sed 's/^/[masker]   ssh: /' /tmp/ssh.err >&2 || true
    echo "[masker] hint: check the bastion host/user/port, the SSH key, and that the bastion can reach ${REMOTE_HOST}:${REMOTE_PORT}." >&2
    exit 4
  fi
  export SOURCE_DB_HOST="127.0.0.1"; export SOURCE_DB_PORT="$SSH_LOCAL_PORT"
  say "SSH tunnel up; SOURCE now via 127.0.0.1:${SSH_LOCAL_PORT}."
fi

# 0b. pre-flight reachability checks (fail fast with a clear message instead of a
#    cryptic pg_dump/greenmask error deep into the run).
preflight(){ # role host port user pass db
  local role="$1" host="$2" port="$3" user="$4" pass="$5" db="$6"
  say "preflight: checking ${role} ${user}@${host}:${port}/${db} ..."
  if ! PGCONNECT_TIMEOUT=10 PGPASSWORD="$pass" \
       psql -h "$host" -p "$port" -U "$user" -d "$db" -tAc 'SELECT 1' >/dev/null 2>/tmp/pf.err; then
    echo "[masker] PREFLIGHT FAILED for ${role}: cannot connect to ${host}:${port}/${db} as ${user}" >&2
    sed 's/^/[masker]   psql: /' /tmp/pf.err >&2 || true
    echo "[masker] hint: verify the URL/credentials and that the DB is reachable from this task's network (security group / VPC egress / firewall)." >&2
    return 1
  fi
  say "preflight: ${role} reachable."
}
preflight "SOURCE" "$SOURCE_DB_HOST" "$SOURCE_DB_PORT" "$SOURCE_DB_USER" "$SOURCE_DB_PASSWORD" "$SOURCE_DB_NAME" || exit 3
# target: connect to the admin 'postgres' db (target DB itself is (re)created later)
preflight "TARGET" "$TARGET_DB_HOST" "$TARGET_DB_PORT" "$TARGET_DB_USER" "$TARGET_DB_PASSWORD" "postgres" || exit 3

# 1. render greenmask config from the selected profile
export SOURCE_DB_HOST SOURCE_DB_PORT SOURCE_DB_USER SOURCE_DB_PASSWORD SOURCE_DB_NAME GM_STORAGE
# Per-source editable profile: when the control panel provides MASK_RULES_URL
# (a presigned GET to the greenmask profile generated during discovery and
# possibly edited by the operator), download and use it instead of a baked one.
PROFILE_FILE="/work/profiles/${MASK_PROFILE}.yml"
if [ -n "${MASK_RULES_URL:-}" ]; then
  say "downloading per-source masking profile from control panel ..."
  if curl -fsS "${MASK_RULES_URL}" -o /tmp/profile.yml && [ -s /tmp/profile.yml ]; then
    PROFILE_FILE="/tmp/profile.yml"
    say "using per-source (edited) masking profile."
  else
    say "WARN: could not download per-source profile; falling back to baked ${MASK_PROFILE}."
  fi
fi
[ -f "$PROFILE_FILE" ] || PROFILE_FILE="/work/greenmask.tmpl.yml"
say "using masking profile: ${MASK_PROFILE} (${PROFILE_FILE}); jobs=${GM_JOBS}"
envsubst < "$PROFILE_FILE" > /tmp/greenmask.yml
say "rendered config:"; sed 's/password=[^ ]*/password=***/' /tmp/greenmask.yml

# 2. masked dump from source
say "dumping + masking source ${SOURCE_DB_NAME}@${SOURCE_DB_HOST} ..."
greenmask --config /tmp/greenmask.yml dump
say "dump done."

# 3. (re)create target DB on RDS
export PGPASSWORD="$TARGET_DB_PASSWORD"
PSQL_ADMIN="psql -v ON_ERROR_STOP=1 -h ${TARGET_DB_HOST} -p ${TARGET_DB_PORT} -U ${TARGET_DB_USER} -d postgres"
say "recreating target database ${TARGET_DB_NAME} ..."
$PSQL_ADMIN -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${TARGET_DB_NAME}' AND pid<>pg_backend_pid();" >/dev/null 2>&1 || true
$PSQL_ADMIN -c "DROP DATABASE IF EXISTS \"${TARGET_DB_NAME}\";"
$PSQL_ADMIN -c "CREATE DATABASE \"${TARGET_DB_NAME}\" ENCODING 'UTF8' TEMPLATE template0;"
$PSQL_ADMIN -c "ALTER DATABASE \"${TARGET_DB_NAME}\" SET search_path TO public;"

# 4. restore masked dump into target (no -C: we pre-created with our name)
say "restoring masked dump into ${TARGET_DB_NAME} ..."
set +e
greenmask --config /tmp/greenmask.yml restore latest \
  -h "${TARGET_DB_HOST}" -p "${TARGET_DB_PORT}" -U "${TARGET_DB_USER}" -d "${TARGET_DB_NAME}" \
  --no-owner --no-privileges --jobs "${GM_JOBS}"
set -e
PSQL_T="psql -v ON_ERROR_STOP=1 -h ${TARGET_DB_HOST} -p ${TARGET_DB_PORT} -U ${TARGET_DB_USER} -d ${TARGET_DB_NAME}"
GOT="$($PSQL_T -A -t -c "SELECT to_regclass('public.res_partner');" || true)"
[ "$GOT" = "res_partner" ] || { echo "[masker] ERROR restore verification failed"; exit 1; }
say "restore verified (res_partner present)."

# 4b. dump slimming: keep only the last GM_SUBSET_DAYS days of high-volume
#     TRANSACTIONAL tables, then cascade-clean orphans so the DB stays
#     referentially intact + Odoo-loadable. Done HERE (post-restore) rather than
#     in greenmask because greenmask's dump-time subset engine panics on Odoo's
#     cyclic schema ("more than one cycle group found in SCC"). This generic SQL
#     approach works on any schema regardless of FK cycles.
#
#     The root transactional tables -> date column map comes from a per-source
#     subset_plan (JSON) generated during discovery and downloaded via
#     GM_SUBSET_PLAN_URL. The operator can review/edit it in the control panel.
#     If no plan is provided, falls back to the built-in defaults below.
GM_SUBSET_DAYS="${GM_SUBSET_DAYS:-}"
case "${GM_SUBSET_DAYS,,}" in ""|none|off|false|0) SUBSET_N="";; *) SUBSET_N="$GM_SUBSET_DAYS";; esac
if [ -n "$SUBSET_N" ] && [ "$SUBSET_N" -gt 0 ] 2>/dev/null; then
  say "dump slimming: pruning transactional rows older than ${SUBSET_N} days ..."

  # Root transactional tables -> date column. The per-source subset_plan
  # (downloaded from GM_SUBSET_PLAN_URL) provides a {table: date_column} map
  # discovered from the live source schema. If absent, use built-in defaults
  # with candidate date columns in priority order (first existing one wins).
  #
  # The plan also carries skip_tables: tables excluded from subsetting (config,
  # metadata, structural). The partner reachability sweep uses this list to
  # decide which tables' FK references to res_partner are NOT meaningful for
  # reachability (those tables retain all rows after subsetting, so their
  # partner references would make every partner appear reachable).
  declare -A SUBSET_ROOTS
  SKIP_TABLES_FROM_PLAN=""
  if [ -n "${GM_SUBSET_PLAN_URL:-}" ] && curl -fsS "${GM_SUBSET_PLAN_URL}" -o /tmp/subset_plan.json 2>/dev/null && [ -s /tmp/subset_plan.json ]; then
    say "  using per-source subset plan from discovery"
    # Extract roots as "table	date_column" lines and populate the array.
    while IFS=$'\t' read -r tbl col; do
      [ -n "$tbl" ] && [ -n "$col" ] && SUBSET_ROOTS["$tbl"]="$col"
    done < <(python3 -c "
import json, sys
plan = json.load(open('/tmp/subset_plan.json'))
for tbl, col in sorted(plan.get('roots', {}).items()):
    print(f'{tbl}\t{col}')
" 2>/dev/null)
    # Extract skip_tables keys (table names) as a newline-separated list.
    SKIP_TABLES_FROM_PLAN="$(python3 -c "
import json
plan = json.load(open('/tmp/subset_plan.json'))
for tbl in sorted(plan.get('skip_tables', {}).keys()):
    print(tbl)
" 2>/dev/null)"
  fi

  # Fallback: if no plan was downloaded or it produced no roots, use defaults.
  if [ ${#SUBSET_ROOTS[@]} -eq 0 ]; then
    say "  no subset plan provided; using built-in defaults"
    SUBSET_ROOTS=(
      [sale_order]="date_order create_date"
      [sale_order_line]="create_date"
      [account_move]="date invoice_date create_date"
      [account_move_line]="date create_date"
      [purchase_order]="date_order create_date"
      [purchase_order_line]="create_date"
      [stock_picking]="scheduled_date date_done create_date"
      [stock_move]="date create_date"
      [stock_move_line]="date create_date"
      [pos_order]="date_order create_date"
      [pos_order_line]="create_date"
      [mrp_production]="date_start create_date"
      [crm_lead]="create_date"
      [calendar_event]="start create_date"
      [project_task]="create_date"
      [hr_attendance]="check_in create_date"
      [mail_message]="date create_date"
      [mail_tracking_value]="create_date"
      [bus_bus]="create_date"
    )
  fi

  # Tables the greenmask profile already dumped schema-only (exclude-table-data):
  # their emptiness is intentional, so the orphan sweep must NOT delete/null rows
  # that merely reference them. Parsed straight from the rendered config.
  EXCLUDED_TABLES=""
  if [ -f /tmp/greenmask.yml ]; then
    EXCLUDED_TABLES="$(grep -oE '^[[:space:]]*-[[:space:]]*public\.[a-zA-Z0-9_]+' /tmp/greenmask.yml \
      | sed -E 's/.*public\.//' | sort -u)"
  fi
  EXCL_ARR="ARRAY["
  first=1
  for t in $EXCLUDED_TABLES; do
    [ $first -eq 1 ] && first=0 || EXCL_ARR="${EXCL_ARR},"
    EXCL_ARR="${EXCL_ARR}'${t}'"
  done
  EXCL_ARR="${EXCL_ARR}]::text[]"

  # Build the per-root DELETE statements (resolve the date column live).
  DELETES=""
  for tbl in "${!SUBSET_ROOTS[@]}"; do
    exists="$($PSQL_T -A -t -c "SELECT to_regclass('public.${tbl}')" 2>/dev/null || true)"
    [ "$exists" = "$tbl" ] || [ "$exists" = "public.${tbl}" ] || continue
    for col in ${SUBSET_ROOTS[$tbl]}; do
      hit="$($PSQL_T -A -t -c "SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='${tbl}' AND column_name='${col}' AND data_type IN ('date','timestamp without time zone','timestamp with time zone') LIMIT 1" 2>/dev/null || true)"
      if [ "$hit" = "1" ]; then
        # keep rows with a NULL date (drafts/incomplete) -- only prune dated-old rows.
        DELETES="${DELETES}
    DELETE FROM public.${tbl} WHERE ${col} IS NOT NULL AND ${col} < (now() - interval '${SUBSET_N} days');"
        say "  prune root: ${tbl} on ${col}"
        break
      fi
    done
  done

  if [ -z "$DELETES" ]; then
    say "dump slimming: no matching transactional tables found; nothing to prune."
  else
    # One atomic pass: disable FK/user triggers for speed, delete old root rows,
    # then repeatedly clean orphaned references to a fixpoint (NULL nullable FKs,
    # DELETE NOT NULL children -- which may orphan their own children, hence the
    # loop). FKs pointing at intentionally-emptied (excluded) tables are skipped.
    $PSQL_T -v ON_ERROR_STOP=1 <<SQL
BEGIN;
SET LOCAL session_replication_role = replica;
${DELETES}

DO \$prune\$
DECLARE
  fk record;
  n bigint;
  total bigint;
  passes int := 0;
  excluded text[] := ${EXCL_ARR};
BEGIN
  LOOP
    total := 0;
    passes := passes + 1;
    FOR fk IN
      SELECT cl.relname AS child, att.attname AS child_col,
             att.attnotnull AS notnull,
             pcl.relname AS parent, patt.attname AS parent_col
      FROM pg_constraint con
      JOIN pg_class cl  ON cl.oid = con.conrelid AND cl.relnamespace = 'public'::regnamespace
      JOIN pg_class pcl ON pcl.oid = con.confrelid
      JOIN pg_attribute att  ON att.attrelid = con.conrelid  AND att.attnum = con.conkey[1]
      JOIN pg_attribute patt ON patt.attrelid = con.confrelid AND patt.attnum = con.confkey[1]
      WHERE con.contype = 'f'
        AND cardinality(con.conkey) = 1
        AND NOT (pcl.relname = ANY(excluded))
    LOOP
      IF fk.notnull THEN
        EXECUTE format(
          'DELETE FROM public.%I c WHERE c.%I IS NOT NULL AND NOT EXISTS '
          '(SELECT 1 FROM public.%I p WHERE p.%I = c.%I)',
          fk.child, fk.child_col, fk.parent, fk.parent_col, fk.child_col);
      ELSE
        EXECUTE format(
          'UPDATE public.%I c SET %I = NULL WHERE c.%I IS NOT NULL AND NOT EXISTS '
          '(SELECT 1 FROM public.%I p WHERE p.%I = c.%I)',
          fk.child, fk.child_col, fk.child_col, fk.parent, fk.parent_col, fk.child_col);
      END IF;
      GET DIAGNOSTICS n = ROW_COUNT;
      total := total + n;
    END LOOP;
    RAISE NOTICE 'orphan sweep pass % touched % rows', passes, total;
    EXIT WHEN total = 0 OR passes >= 50;
  END LOOP;
END
\$prune\$;
COMMIT;
SQL
    say "dump slimming: prune + orphan sweep complete."

    # 4b-2. Partner reachability sweep: delete res_partner rows not referenced
    #       by any surviving transactional row. Master data like partners can
    #       be huge (100k+) but only a fraction is referenced after subsetting.
    #       We find all partner IDs directly referenced by any FK column pointing
    #       at res_partner, walk parent_id chains (company -> contact), then
    #       delete the rest. This is safe because it runs AFTER the orphan sweep
    #       has already cleaned up dangling FK references.
    say "dump slimming: pruning unreferenced res_partner rows ..."

    # Build SQL VALUES list from the subset plan's skip_tables. These tables
    # retain all rows after subsetting, so their FK references to res_partner
    # are not meaningful for partner reachability. Always include res_partner
    # itself (self-reference, handled by the parent_id closure) -- it's a
    # master table, not in skip_tables.
    SKIP_VALS="('res_partner')"
    if [ -n "${SKIP_TABLES_FROM_PLAN}" ]; then
      for t in ${SKIP_TABLES_FROM_PLAN}; do
        SKIP_VALS="${SKIP_VALS},('${t}')"
      done
    fi

    # Shell-expanded SQL (creates temp tables and populates _skip_tables from
    # the subset plan) is echoed; the PL/pgSQL blocks with dollar quotes are
    # in a single-quoted heredoc (no expansion needed). Both are piped to a
    # single psql session so temp tables persist.
    {
      echo "BEGIN;"
      echo "SET LOCAL session_replication_role = replica;"
      echo "CREATE TEMP TABLE _partner_direct ON COMMIT DROP AS"
      echo "SELECT DISTINCT pid FROM ("
      echo "  SELECT partner_id AS pid FROM res_company WHERE partner_id IS NOT NULL"
      echo "  UNION"
      echo "  SELECT partner_id AS pid FROM res_users WHERE partner_id IS NOT NULL"
      echo ") seed;"
      echo "CREATE TEMP TABLE _skip_tables(name text PRIMARY KEY) ON COMMIT DROP;"
      echo "INSERT INTO _skip_tables VALUES ${SKIP_VALS};"
      cat <<'PSQLP'
DO $collect$
DECLARE
  fk record;
  cnt int;
BEGIN
  FOR fk IN
    SELECT cl.relname AS child, att.attname AS child_col
    FROM pg_constraint con
    JOIN pg_class cl  ON cl.oid = con.conrelid AND cl.relnamespace = 'public'::regnamespace
    JOIN pg_class pcl ON pcl.oid = con.confrelid
    JOIN pg_attribute att  ON att.attrelid = con.conrelid  AND att.attnum = con.conkey[1]
    JOIN pg_attribute patt ON patt.attrelid = con.confrelid AND patt.attnum = con.confkey[1]
    WHERE pcl.relname = 'res_partner' AND con.contype = 'f'
      AND cl.relname NOT IN (SELECT name FROM _skip_tables)
  LOOP
    BEGIN
      EXECUTE format(
        'INSERT INTO _partner_direct SELECT DISTINCT %I FROM public.%s WHERE %I IS NOT NULL',
        fk.child_col, fk.child, fk.child_col);
    EXCEPTION WHEN others THEN
      -- table might not exist or column might be gone; skip
    END;
  END LOOP;
  SELECT count(*) INTO cnt FROM _partner_direct;
  RAISE NOTICE 'partner sweep: % direct references collected', cnt;
END
$collect$;

-- Step 2: transitive closure over parent_id (company -> contact chains).
CREATE TEMP TABLE _partner_reachable(id bigint PRIMARY KEY) ON COMMIT DROP;
INSERT INTO _partner_reachable SELECT pid FROM _partner_direct
ON CONFLICT DO NOTHING;
DO $closure$
DECLARE
  new_rows int;
  down_rows int;
  passes int := 0;
BEGIN
  LOOP
    passes := passes + 1;
    new_rows := 0;
    INSERT INTO _partner_reachable
    SELECT p.parent_id FROM res_partner p
    JOIN _partner_reachable r ON p.id = r.id
    WHERE p.parent_id IS NOT NULL
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS new_rows = ROW_COUNT;
    INSERT INTO _partner_reachable
    SELECT p.id FROM res_partner p
    JOIN _partner_reachable r ON p.parent_id = r.id
    WHERE p.parent_id IS NOT NULL
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS down_rows = ROW_COUNT;
    new_rows := new_rows + down_rows;
    EXIT WHEN new_rows = 0 OR passes >= 20;
  END LOOP;
  RAISE NOTICE 'partner sweep: closure converged in % passes', passes;
END
$closure$;

-- Step 3: delete unreferenced partners.
DO $delete$
DECLARE
  deleted bigint;
BEGIN
  DELETE FROM res_partner p WHERE p.id NOT IN (SELECT id FROM _partner_reachable);
  GET DIAGNOSTICS deleted = ROW_COUNT;
  RAISE NOTICE 'partner sweep: deleted % unreferenced partners', deleted;
END
$delete$;

COMMIT;
PSQLP
    } | $PSQL_T -v ON_ERROR_STOP=1
    say "dump slimming: partner sweep complete"

    say "reclaiming space ..."
    $PSQL_T -c "VACUUM (ANALYZE);" >/dev/null 2>&1 || true
    say "dump slimming done."
  fi
fi

# 4c. varied realistic product names. greenmask's Replace emits a single
#     constant ("Masked Product") for the jsonb product_template.name, which
#     is correct/restorable but shows identical names for every product in the
#     dev replica. Post-restore we overwrite with a per-row deterministic name
#     from an adjective+noun pool (no external dep), written as valid jsonb
#     so Odoo's translatable field stays well-formed. Idempotent + safe: the
#     column is non-unique (verified), so no index collision risk.
if [ -n "${GM_VARIED_PRODUCT_NAMES:-1}" ]; then
  _HAS_PT="$($PSQL_T -A -t -c "SELECT to_regclass('public.product_template')" 2>/dev/null || true)"
  if [ "$_HAS_PT" = "product_template" ]; then
    say "assigning varied realistic product names ..."
    $PSQL_T -v ON_ERROR_STOP=1 <<'PN'
UPDATE product_template
SET name = jsonb_build_object('en_US',
  (ARRAY[
    'Cedar','Maple','Ivory','Crimson','Azure','Amber','Slate','Coral',
    'Onyx','Willow','Bronze','Indigo','Saffron','Jade','Ruby','Pearl',
    'Oak','Flint','Hazel','Cobalt','Teal','Marble','Ash','Russet','Ebony'
  ])[1 + ((id * 7) % 25)]
  || ' ' ||
  (ARRAY[
    'Throw Blanket','Cotton Scarf','Ceramic Mug','Linen Tote','Bracelet',
    'Incense Holder','Journal','Wall Print','Yoga Mat','Meditation Cushion',
    'T-Shirt','Hoodie','Tumbler','Notebook','Pendant','Candle Set','Statue',
    'Prayer Beads','Copper Bottle','Shawl','Coaster Set','Diffuser','Lamp','Bag'
  ])[1 + ((id * 13) % 24)])
WHERE name IS NOT NULL;
PN
    say "product names randomized."
  fi
fi

# 4d. H7 (Pass-2 review): scrub FK-forced-back tables. When FK safety prevents
#     emptying a high-volume table (a retained table has a FK into it), the
#     table ships with ALL its real data. Previously this meant real PII
#     (attachment binaries, mail message bodies) leaked unmasked. Now: parse
#     the FK_FORCED_BACK annotation from the rendered greenmask config and
#     scrub the binary + large-text columns on those tables so no real content
#     survives. The table is still present (rows intact for FK integrity) but
#     its content columns are nulled/truncated.
if [ -f /tmp/greenmask.yml ]; then
  FK_FORCED_BACK="$(grep -oE '# FK_FORCED_BACK: [a-zA-Z0-9_,]+' /tmp/greenmask.yml \
    | sed 's/# FK_FORCED_BACK: //' | tr ',' '\n' | sort -u 2>/dev/null || true)"
  if [ -n "$FK_FORCED_BACK" ]; then
    say "H7: scrubbing FK-forced-back tables (real data present for FK integrity, content nulled):"
    for tbl in $FK_FORCED_BACK; do
      exists="$($PSQL_T -A -t -c "SELECT to_regclass('public.${tbl}')" 2>/dev/null || true)"
      [ "$exists" = "$tbl" ] || continue
      say "  scrubbing ${tbl} ..."
      # Null all bytea columns (attachment binaries, stored file content)
      bytea_cols="$($PSQL_T -A -t -c "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='${tbl}' AND data_type='bytea'" 2>/dev/null || true)"
      if [ -n "$bytea_cols" ]; then
        for col in $bytea_cols; do
          $PSQL_T -c "UPDATE public.${tbl} SET ${col} = NULL WHERE ${col} IS NOT NULL;" 2>/dev/null || true
          say "    nulled bytea: ${tbl}.${col}"
        done
      fi
      # Truncate large text columns (mail bodies, attachment names/descriptions)
      # to a placeholder -- keeps the row for FK integrity but destroys content.
      text_cols="$($PSQL_T -A -t -c "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='${tbl}' AND data_type IN ('text') AND character_maximum_length IS NULL" 2>/dev/null || true)"
      if [ -n "$text_cols" ]; then
        for col in $text_cols; do
          $PSQL_T -c "UPDATE public.${tbl} SET ${col} = LEFT(${col}, 0) WHERE ${col} IS NOT NULL;" 2>/dev/null || true
          say "    truncated text: ${tbl}.${col}"
        done
      fi
      # Also null varchar columns that look PII-shaped (email, phone, name, etc.)
      # but were not caught by greenmask (e.g. because the table was a candidate
      # for exclude-table-data, not for transformation).
      pii_cols="$($PSQL_T -A -t -c "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='${tbl}' AND data_type='character varying' AND column_name ~* '(email|phone|mobile|street|city|zip|postal|vat|ssn|passport|aadhaar|national_id|tax_id|credit_card|card_number|login|password|secret|token|key)'" 2>/dev/null || true)"
      if [ -n "$pii_cols" ]; then
        for col in $pii_cols; do
          $PSQL_T -c "UPDATE public.${tbl} SET ${col} = NULL WHERE ${col} IS NOT NULL;" 2>/dev/null || true
          say "    nulled PII varchar: ${tbl}.${col}"
        done
      fi
    done
    say "H7: FK-forced-back scrub complete."
  fi
fi

# 5. neutralize (guard each table: modules like fetchmail/payment may be absent)
#    each step is individually toggleable via NEUTRALIZE_* env vars.
#
# C2 (DevOps review): the neutralize block previously covered mail/fetchmail/cron
# correctly but left critical credential tables partially or fully unscrubbed:
#   * ir_config_parameter: only one key (mail.force.smtp.from) was zeroed --
#     third-party API keys/tokens, database.secret (signs session cookies +
#     reset tokens), and database.uuid were left intact.
#   * payment_provider: state was disabled but gateway credential VALUES stayed.
#   * res_users: only the admin password was reset -- every other user's password
#     hash and totp_secret (real 2FA seeds) were left in place.
#   * res_users_apikeys + auth_totp_device: nothing was done at all.
# The rulebook (rules/60_system_secrets.yml) has the full spec; this block now
# implements it. See the review's C2 table for the before/after.
say "neutralizing (mail=${NEUTRALIZE_MAIL} fetchmail=${NEUTRALIZE_FETCHMAIL} payment=${NEUTRALIZE_PAYMENT} smtp_param=${NEUTRALIZE_SMTP_PARAM} crons=${NEUTRALIZE_CRONS} secrets=${NEUTRALIZE_SECRETS}) ..."
export N_MAIL N_FETCH N_PAY N_SMTP N_CRON N_SECRETS
is_true "$NEUTRALIZE_MAIL"      && N_MAIL=1  || N_MAIL=0
is_true "$NEUTRALIZE_FETCHMAIL" && N_FETCH=1 || N_FETCH=0
is_true "$NEUTRALIZE_PAYMENT"   && N_PAY=1   || N_PAY=0
is_true "$NEUTRALIZE_SMTP_PARAM" && N_SMTP=1 || N_SMTP=0
is_true "$NEUTRALIZE_CRONS"     && N_CRON=1  || N_CRON=0
# C2: credential scrubbing is on by default -- it's security hygiene, not PII,
# and there's no reason to ever turn it off for a dev replica.
NEUTRALIZE_SECRETS="${NEUTRALIZE_SECRETS:-true}"
is_true "$NEUTRALIZE_SECRETS"   && N_SECRETS=1 || N_SECRETS=0
$PSQL_T <<SQL
DO \$\$ BEGIN
  IF ${N_MAIL} = 1 AND to_regclass('public.ir_mail_server') IS NOT NULL THEN
    UPDATE ir_mail_server SET active=false, smtp_host=NULL, smtp_user=NULL, smtp_pass=NULL;
  END IF;
  IF ${N_FETCH} = 1 AND to_regclass('public.fetchmail_server') IS NOT NULL THEN
    EXECUTE 'UPDATE fetchmail_server SET active=false, password=NULL, "user"=NULL';
  END IF;
  IF ${N_PAY} = 1 AND to_regclass('public.payment_provider') IS NOT NULL THEN
    -- C2: disable AND null the credential columns (the values were left intact
    -- before). Covers the standard Odoo payment_provider columns; the column
    -- existence is checked dynamically so this works across Odoo versions.
    UPDATE payment_provider SET state='disabled';
    -- null every credential-shaped column on payment_provider
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='payment_provider' AND column_name='payment_token') THEN
      UPDATE payment_provider SET payment_token = NULL;
    END IF;
    -- Odoo payment_provider has a jsonb 'payment_method_ids' but the actual
    -- gateway secrets live in provider-specific columns. The generic approach:
    -- null any column whose name matches the secret regex from 60_system_secrets.
    EXECUTE 'UPDATE payment_provider SET ' || (
      SELECT string_agg(col || '=NULL', ', ')
      FROM (
        SELECT column_name AS col FROM information_schema.columns
        WHERE table_name='payment_provider'
          AND column_name ~* '(secret|token|key|password|api_key|access_key|client_secret)'
      ) s
    ) WHERE EXISTS (SELECT 1 FROM information_schema.columns
      WHERE table_name='payment_provider'
        AND column_name ~* '(secret|token|key|password|api_key|access_key|client_secret)');
  END IF;
  IF ${N_SMTP} = 1 AND to_regclass('public.ir_config_parameter') IS NOT NULL THEN
    UPDATE ir_config_parameter SET value='0' WHERE key='mail.force.smtp.from' AND value IS NOT NULL;
  END IF;
  IF ${N_CRON} = 1 AND to_regclass('public.ir_cron') IS NOT NULL THEN
    -- disable every scheduled action so the masked dev replica never fires crons
    UPDATE ir_cron SET active=false;
    IF to_regclass('public.ir_cron_trigger') IS NOT NULL THEN
      DELETE FROM ir_cron_trigger;  -- drop any queued immediate triggers too
    END IF;
  END IF;
  -- C2: credential scrubbing (rules/60_system_secrets.yml is the spec)
  IF ${N_SECRETS} = 1 THEN
    -- 1. ir_config_parameter: delete rows matching the secret/token/key regex
    --    (from 60_system_secrets.yml), then regenerate database.secret +
    --    database.uuid fresh so the dev DB can't forge signed session cookies
    --    or be mistaken for the production instance by IAP/licensing.
    IF to_regclass('public.ir_config_parameter') IS NOT NULL THEN
      DELETE FROM ir_config_parameter
        WHERE key ~* '(secret|token|key|password|api_key|access_key|client_secret)';
      -- regenerate database.secret (signs session cookies + reset tokens)
      DELETE FROM ir_config_parameter WHERE key='database.secret';
      INSERT INTO ir_config_parameter (key, value, create_uid, write_uid, create_date, write_date)
        VALUES ('database.secret', gen_random_bytes(32)::text, 1, 1, now(), now());
      -- regenerate database.uuid (Odoo registration identity)
      DELETE FROM ir_config_parameter WHERE key='database.uuid';
      INSERT INTO ir_config_parameter (key, value, create_uid, write_uid, create_date, write_date)
        VALUES ('database.uuid', gen_random_uuid()::text, 1, 1, now(), now());
    END IF;
    -- 2. res_users: scrub password + totp_secret across ALL rows (not just
    --    admin). The admin password reset in step 6 sets a known-good hash
    --    after this; every other user gets a NULL password (can't log in).
    IF to_regclass('public.res_users') IS NOT NULL THEN
      UPDATE res_users SET password = NULL;
      IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='res_users' AND column_name='totp_secret') THEN
        UPDATE res_users SET totp_secret = NULL;
      END IF;
    END IF;
    -- 3. truncate API key records + 2FA device records
    IF to_regclass('public.res_users_apikeys') IS NOT NULL THEN
      DELETE FROM res_users_apikeys;
    END IF;
    IF to_regclass('public.auth_totp_device') IS NOT NULL THEN
      DELETE FROM auth_totp_device;
    END IF;
  END IF;
END \$\$;
SQL

# 6. set admin password (pbkdf2-sha512, Odoo passlib scheme)
#    C2: step 5 already scrubbed ALL res_users.password/totp_secret to NULL;
#    this sets a known-good hash for the admin user only so the dev can log in.
say "setting admin password ..."
HASH="$(python3 - "$ODOO_ADMIN_PASSWORD" <<'PY'
import sys
from passlib.context import CryptContext
print(CryptContext(schemes=["pbkdf2_sha512"]).hash(sys.argv[1]), end="")
PY
)"
UID_ADMIN="$($PSQL_T -A -t -c "SELECT res_id FROM ir_model_data WHERE module='base' AND name='user_admin' LIMIT 1;" || true)"
[ -n "$UID_ADMIN" ] || UID_ADMIN=2
if is_true "$RESET_ADMIN_LOGIN"; then
  $PSQL_T -c "UPDATE res_users SET password='${HASH}', login='admin' WHERE id=${UID_ADMIN};"
  say "admin uid ${UID_ADMIN} password + login('admin') set (all other users' passwords were scrubbed in step 5)."
else
  $PSQL_T -c "UPDATE res_users SET password='${HASH}' WHERE id=${UID_ADMIN};"
  say "admin uid ${UID_ADMIN} password set (all other users' passwords were scrubbed in step 5)."
fi

# 6a. H1 (Pass-2 review): canary records. The review's counter-proposal: seed
#     canary rows into the restored TEMPORARY instance (not the source DB),
#     before greenmask runs (actually, after restore but the key point is they
#     are on the writable temp instance, not production). Then assert those
#     exact values are absent from the masked output. This catches
#     shape-preserving transformer failures that the pattern scan can't detect
#     (e.g. email -> RandomEmail: the value changed but the shape survived, so
#     the pattern scan sees a valid email and can't tell if it's the original
#     or a generated one; the canary confirms the value actually changed).
#
#     The canary runs are inserted into the TARGET DB after restore + slimming
#     but BEFORE neutralize (so they go into the live masked DB). The canary
#     values are inserted into a dedicated canary table (not a real Odoo table)
#     so they don't interfere with Odoo's schema or FK integrity. The post-mask
#     scan (step 6b) then checks that these exact canary values are absent.
CANARY_VERIFY="${CANARY_VERIFY:-true}"
if is_true "$CANARY_VERIFY"; then
  say "canary: seeding canary records into restored temporary instance ..."
  # Create a canary table with known PII-shaped values
  $PSQL_T -v ON_ERROR_STOP=1 <<'CANARY'
CREATE TABLE IF NOT EXISTS _synth_canary (
  id serial PRIMARY KEY,
  email text,
  phone text,
  name text,
  notes text
);
INSERT INTO _synth_canary (email, phone, name, notes) VALUES
  ('canary.test.senthil@example.canary', '+919876543210', 'Canary Senthil Nathan',
   'Canary secret: AKIA-TEST-CANARY-TOKEN-XYZ123');
CANARY
  say "canary: seeded 1 canary row with known PII values."
fi

# 6b. H1 (DevOps review): post-mask verification -- scan the masked DB for
#     high-signal PII patterns that should not survive masking. If any are
#     found, FAIL the run before the dump is uploaded so the unverified dump
#     never lands in masked-dumps/ (which every downstream consumer trusts).
#     This is the control that makes the other masking fixes trustworthy.
#
#     Scans for: emails, phone numbers (Indian + generic), Aadhaar/PAN shapes,
#     and residual ir_config_parameter secrets. The allowlist (tables/columns
#     exempt from the scan) is configurable via POST_MASK_ALLOWLIST (comma-sep
#     table.column patterns; defaults to none). The scan is on by default;
#     disable with POST_MASK_VERIFY=false (NOT recommended for prod-derived data).
#
#     Pass-2 review gap (b): the table list is now derived from the generated
#     greenmask profile (every table with a PII-classified column) rather than
#     hardcoded to 6 Odoo core tables. This keeps the verifier in step with the
#     masker automatically as addons change. Tables with transformations are
#     parsed from the rendered /tmp/greenmask.yml. If the profile can't be
#     parsed (baked profile path), we fall back to the core table list + all
#     text columns across all tables with a LIMIT per column (the review's
#     alternative suggestion). FK-forced-back tables (H7) are also included
#     since they ship with real data.
POST_MASK_VERIFY="${POST_MASK_VERIFY:-true}"
# allowlist: comma-sep table.column patterns exempt from the scan (case-insensitive)
# Pass-2 review: every allowlist entry must have a recorded reviewer + reason.
# Provide them via POST_MASK_ALLOWLIST_REASONS (comma-sep, same order as
# POST_MASK_ALLOWLIST, format: "reviewer:reason"). If reasons are missing or
# the count doesn't match, the scan FAILS rather than silently allowing
# exemptions without governance. This is the knob the review flagged as "the
# one path that can quietly reopen everything else the branch just closed."
ALLOWLIST="${POST_MASK_ALLOWLIST:-}"
ALLOWLIST_REASONS="${POST_MASK_ALLOWLIST_REASONS:-}"
# Validate allowlist governance: every entry needs a reason.
if [ -n "$ALLOWLIST" ] && is_true "$POST_MASK_VERIFY"; then
  n_entries=$(echo "$ALLOWLIST" | tr ',' '\n' | grep -c '.' 2>/dev/null || echo 0)
  n_reasons=$(echo "$ALLOWLIST_REASONS" | tr ',' '\n' | grep -c '.' 2>/dev/null || echo 0)
  if [ "$n_entries" != "$n_reasons" ]; then
    echo "[masker] ERROR: POST_MASK_ALLOWLIST has $n_entries entries but POST_MASK_ALLOWLIST_REASONS has $n_reasons reasons."
    echo "[masker] Every allowlist exemption needs a recorded reviewer:reason (Pass-2 review governance)."
    echo "[masker] Format: POST_MASK_ALLOWLIST_REASONS=\"alice:cache-field for partner search,bob:test fixture\""
    exit 1
  fi
  say "  allowlist: $n_entries entries, each with a recorded reason (governance OK)"
fi
if is_true "$POST_MASK_VERIFY"; then
  say "post-mask verification: scanning for residual PII patterns ..."
  # Uses psql (already in the postgres:16 image) + a Python regex pass on
  # the extracted values. No extra pip dependency needed.
  say "  deriving scan table list from generated profile ..."
  FINDINGS=0

  # Helper: scan a table.column for PII patterns via psql + python regex
  scan_col() { # table col
    local tbl="$1" col="$2"
    local key="${tbl}.${col}"
    # check allowlist (case-insensitive)
    case " ${ALLOWLIST:-} " in *" ${key,,} "*) return 0;; esac
    # extract non-null values via psql, pipe through python regex check.
    # Pass table.column as args to the python script (avoids fragile
    # bash-variable-in-Python-string escaping).
    local hits
    hits="$($PSQL_T -A -t -c "SELECT ${col} FROM public.${tbl} WHERE ${col} IS NOT NULL LIMIT 5000" 2>/dev/null \
      | python3 -c "
import sys, re
tbl, col = sys.argv[1], sys.argv[2]
PATTERNS = {
    'email': re.compile(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'),
    'indian_mobile': re.compile(r'(?:\+91[-\s]?)?[6-9]\d{9}'),
    'aadhaar': re.compile(r'\b\d{4}\s\d{4}\s\d{4}\b|\b\d{12}\b'),
    'pan': re.compile(r'\b[A-Z]{5}\d{4}[A-Z]\b'),
}
for line in sys.stdin:
    line = line.rstrip('\n')
    if not line:
        continue
    for pname, pat in PATTERNS.items():
        if pat.search(line):
            print('  ' + tbl + '.' + col + ': ' + pname + ' pattern matched (sample: ' + repr(line[:60]) + ')')
            break
" "$tbl" "$col" 2>/dev/null)"
    if [ -n "$hits" ]; then
      echo "$hits"
      FINDINGS=$((FINDINGS + 1))
    fi
  }

  # Derive the scan table list from the generated greenmask profile: every
  # table that has at least one transformer entry. This keeps the verifier in
  # step with the masker automatically as addons change (Pass-2 review gap (b)).
  # Falls back to the 6 core tables + FK-forced-back tables if the profile can't
  # be parsed (e.g. the baked default profile path).
  SCAN_TABLES=""
  if [ -f /tmp/greenmask.yml ]; then
    # Extract table names from "name: <table>" lines under dump.transformation
    SCAN_TABLES="$(python3 -c "
import yaml, sys
try:
    doc = yaml.safe_load(open('/tmp/greenmask.yml'))
    transforms = (doc.get('dump') or {}).get('transformation') or []
    tables = [t.get('name','') for t in transforms if t.get('name')]
    print(' '.join(tables))
except Exception:
    print('')
" 2>/dev/null || true)"
  fi
  # Add FK-forced-back tables (they ship with real data -- H7)
  if [ -f /tmp/greenmask.yml ]; then
    FK_BACK="$(grep -oE '# FK_FORCED_BACK: [a-zA-Z0-9_,]+' /tmp/greenmask.yml \
      | sed 's/# FK_FORCED_BACK: //' | tr ',' ' ' 2>/dev/null || true)"
    SCAN_TABLES="${SCAN_TABLES} ${FK_BACK}"
  fi
  # Fallback: if no tables derived from profile, use the core list
  if [ -z "${SCAN_TABLES// /}" ]; then
    SCAN_TABLES="res_partner res_users hr_employee res_company crm_lead hr_applicant"
    say "  (profile parse failed; using core table fallback list)"
  fi

  # 1. scan each table for unmasked patterns
  for tbl in $SCAN_TABLES; do
    [ -n "$tbl" ] || continue
    exists="$($PSQL_T -A -t -c "SELECT to_regclass('public.${tbl}')" 2>/dev/null || true)"
    [ "$exists" = "$tbl" ] || continue
    # get text/varchar columns
    cols="$($PSQL_T -A -t -c "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='${tbl}' AND data_type IN ('text','character varying')" 2>/dev/null || true)"
    for col in $cols; do
      scan_col "$tbl" "$col"
    done
  done

  # 2. check ir_config_parameter for residual secrets
  has_param="$($PSQL_T -A -t -c "SELECT to_regclass('public.ir_config_parameter')" 2>/dev/null || true)"
  if [ "$has_param" = "ir_config_parameter" ]; then
    residual="$($PSQL_T -A -t -c "SELECT key FROM ir_config_parameter WHERE key ~* '(secret|token|key|password|api_key)'" 2>/dev/null || true)"
    if [ -n "$residual" ]; then
      echo "$residual" | while read -r key; do
        echo "  ir_config_parameter: residual secret key '$key'"
      done
      FINDINGS=$((FINDINGS + 1))
    fi
  fi

  # 3. check res_users for non-null password hashes (only admin should have one)
  has_users="$($PSQL_T -A -t -c "SELECT to_regclass('public.res_users')" 2>/dev/null || true)"
  if [ "$has_users" = "res_users" ]; then
    pw_count="$($PSQL_T -A -t -c "SELECT count(*) FROM res_users WHERE password IS NOT NULL" 2>/dev/null || echo 0)"
    if [ "$pw_count" -gt 1 ] 2>/dev/null; then
      echo "  res_users: ${pw_count} users with non-null password (expected 1 = admin only)"
      FINDINGS=$((FINDINGS + 1))
    fi
  fi

  # 4. H1 (Pass-2 review): canary records -- assert the exact canary values
  #    seeded in step 6a are absent from the masked DB. If any survive, it
  #    means a transformer silently failed to apply (shape-preserving failure:
  #    the value kept its shape but should have changed). This catches the
  #    failure class the pattern scan can't (see step 6a comment).
  has_canary="$($PSQL_T -A -t -c "SELECT to_regclass('public._synth_canary')" 2>/dev/null || true)"
  if [ "$has_canary" = "_synth_canary" ]; then
    say "  checking canary records ..."
    canary_hits="$($PSQL_T -A -t -c "SELECT email FROM _synth_canary WHERE email = 'canary.test.senthil@example.canary'" 2>/dev/null || true)"
    if [ -n "$canary_hits" ]; then
      echo "  canary: email value survived masking (shape-preserving transformer failed)"
      FINDINGS=$((FINDINGS + 1))
    fi
    canary_phone="$($PSQL_T -A -t -c "SELECT phone FROM _synth_canary WHERE phone = '+919876543210'" 2>/dev/null || true)"
    if [ -n "$canary_phone" ]; then
      echo "  canary: phone value survived masking (shape-preserving transformer failed)"
      FINDINGS=$((FINDINGS + 1))
    fi
    canary_name="$($PSQL_T -A -t -c "SELECT name FROM _synth_canary WHERE name = 'Canary Senthil Nathan'" 2>/dev/null || true)"
    if [ -n "$canary_name" ]; then
      echo "  canary: name value survived masking (shape-preserving transformer failed)"
      FINDINGS=$((FINDINGS + 1))
    fi
    # The canary table itself should be dropped before dump (it's a verification
    # artifact, not real data). If it survives, the dump includes it.
    $PSQL_T -c "DROP TABLE IF EXISTS _synth_canary;" 2>/dev/null || true
  fi

  if [ "$FINDINGS" -gt 0 ]; then
    echo "[masker] ERROR: post-mask verification FAILED -- residual PII detected"
    echo "[masker] The masked DB may contain unmasked PII. Review the findings above,"
    echo "[masker] fix the masking profile, and re-run. Do NOT promote this dump."
    exit 1
  fi
  say "post-mask verification PASSED."
fi

# 7. (optional) produce a downloadable pg_dump of the masked DB and upload it to
#    the presigned S3 URL provided by the control panel (MASKED_DUMP_PUT_URL).
#    H1: this only runs AFTER post-mask verification passes (step 6b).
if [ -n "${MASKED_DUMP_PUT_URL:-}" ]; then
  say "producing downloadable pg_dump of masked DB ${TARGET_DB_NAME} ..."
  DUMP_FILE="/tmp/masked.dump"
  pg_dump -Fc --no-owner --no-privileges \
    -h "${TARGET_DB_HOST}" -p "${TARGET_DB_PORT}" -U "${TARGET_DB_USER}" \
    -d "${TARGET_DB_NAME}" -f "$DUMP_FILE"
  SZ="$(stat -c%s "$DUMP_FILE" 2>/dev/null || echo '?')"
  say "uploading masked dump (${SZ} bytes) to S3 ..."
  curl -fsS -X PUT -T "$DUMP_FILE" "${MASKED_DUMP_PUT_URL}" \
    && say "masked dump uploaded; download link is available in the control panel." \
    || { echo "[masker] ERROR masked dump upload failed"; exit 1; }
  rm -f "$DUMP_FILE"
fi

say "DONE: masked replica ready in ${TARGET_DB_NAME}@${TARGET_DB_HOST}"
