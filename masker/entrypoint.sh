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
  say "opening SSH tunnel: localhost:${SSH_LOCAL_PORT} -> ${REMOTE_HOST}:${REMOTE_PORT} via ${SSH_BASTION_USER}@${SSH_BASTION_HOST}:${SSH_BASTION_PORT} ..."
  if ! ssh -f -N \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
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
GM_SUBSET_DAYS="${GM_SUBSET_DAYS:-}"
case "${GM_SUBSET_DAYS,,}" in ""|none|off|false|0) SUBSET_N="";; *) SUBSET_N="$GM_SUBSET_DAYS";; esac
if [ -n "$SUBSET_N" ] && [ "$SUBSET_N" -gt 0 ] 2>/dev/null; then
  say "dump slimming: pruning transactional rows older than ${SUBSET_N} days ..."

  # Root transactional tables -> candidate date columns in priority order. The
  # first column that actually exists (date/timestamp) is used; tables/columns
  # absent from the source are skipped, so this stays general across Odoo
  # versions/modules. Master data (partners, products, journals, companies) is
  # never a root here -- it is referenced BY these tables and is retained.
  declare -A SUBSET_ROOTS=(
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
    say "dump slimming: prune + orphan sweep complete; reclaiming space ..."
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

# 7. (optional) produce a downloadable pg_dump of the masked DB and upload it to
#    the presigned S3 URL provided by the control panel (MASKED_DUMP_PUT_URL).
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
