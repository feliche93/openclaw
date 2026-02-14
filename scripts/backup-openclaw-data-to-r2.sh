#!/usr/bin/env bash
set -euo pipefail

# Backup OpenClaw persisted data dir to Cloudflare R2 using restic (S3 backend).
#
# Intended to run INSIDE the OpenClaw container as a Coolify Scheduled Task.
# This backs up the mounted /data volume (OpenClaw state + workspace) only.
#
# NOTE (Coolify + Infisical):
# Coolify runs Scheduled Tasks via `docker exec`, which does NOT inherit the
# environment injected by `infisical run ... /app/scripts/entrypoint.sh`.
# To keep scheduled tasks working when secrets live only in Infisical, this
# script can re-exec itself under `infisical run` when INFISICAL_* is configured.
#
# Required env:
#   R2_ENDPOINT               e.g. https://<accountid>.r2.cloudflarestorage.com
#   R2_BUCKET                 e.g. my-backups
#   R2_ACCESS_KEY_ID
#   R2_SECRET_ACCESS_KEY
#   RESTIC_PASSWORD           encryption password (store safely)
#
# Optional env:
#   BACKUP_DIR                default: /data
#   R2_PREFIX                 default: coolify/openclaw-data/<COOLIFY_RESOURCE_UUID>
#   RESTIC_TAG                default: openclaw-data
#   KEEP_DAILY                default: 7
#   KEEP_WEEKLY               default: 4
#   KEEP_MONTHLY              default: 6

die() { echo "[backup] ERROR: $*" >&2; exit 1; }

command -v restic >/dev/null 2>&1 || die "restic not found (image must include it)"

ensure_infisical_injection_if_needed() {
  # If the required vars are already present, nothing to do.
  if [ -n "${R2_ENDPOINT:-}" ] \
    && [ -n "${R2_BUCKET:-}" ] \
    && [ -n "${R2_ACCESS_KEY_ID:-}" ] \
    && [ -n "${R2_SECRET_ACCESS_KEY:-}" ] \
    && [ -n "${RESTIC_PASSWORD:-}" ]; then
    return 0
  fi

  # Avoid loops: if we already wrapped with Infisical and vars are still missing, fail hard.
  if [ -n "${BACKUP_INFISICAL_WRAPPED:-}" ]; then
    return 0
  fi

  # If Infisical isn't configured, just proceed to the normal validation errors below.
  if [ -z "${INFISICAL_PROJECT_ID:-}" ]; then
    return 0
  fi

  command -v infisical >/dev/null 2>&1 || return 0

  INFISICAL_API_URL="${INFISICAL_API_URL:-https://app.infisical.com/api}"
  INFISICAL_ENV_EFFECTIVE="${INFISICAL_ENV:-prod}"
  INFISICAL_PATH_EFFECTIVE="${INFISICAL_PATH:-/}"

  INFISICAL_RUNTIME_TOKEN=""
  if [ -n "${INFISICAL_TOKEN:-}" ]; then
    INFISICAL_RUNTIME_TOKEN="$INFISICAL_TOKEN"
  elif [ -n "${INFISICAL_CLIENT_ID:-}" ] && [ -n "${INFISICAL_CLIENT_SECRET:-}" ]; then
    # Mirror entrypoint.sh: fetch access token via Universal Auth.
    INFISICAL_RUNTIME_TOKEN="$(node -e "
      const api = (process.env.INFISICAL_API_URL || 'https://app.infisical.com/api').replace(/\\/+$/,'');
      const clientId = process.env.INFISICAL_CLIENT_ID;
      const clientSecret = process.env.INFISICAL_CLIENT_SECRET;
      if (!clientId || !clientSecret) process.exit(2);
      fetch(api + '/v1/auth/universal-auth/login', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ clientId, clientSecret })
      }).then(async (res) => {
        const txt = await res.text();
        let j;
        try { j = JSON.parse(txt); } catch { throw new Error('non-json response'); }
        const tok = j && (j.accessToken || j.access_token || (j.data && j.data.accessToken));
        if (!res.ok || !tok) process.exit(1);
        process.stdout.write(tok);
      }).catch(() => process.exit(1));
    " 2>/dev/null || true)"
  fi

  if [ -z "${INFISICAL_RUNTIME_TOKEN:-}" ]; then
    # Fall through to the normal "R2_* required" validation for a clear error.
    return 0
  fi

  echo "[backup] infisical: injecting secrets for scheduled task (env=$INFISICAL_ENV_EFFECTIVE path=$INFISICAL_PATH_EFFECTIVE)"
  exec infisical run \
    --domain "$INFISICAL_API_URL" \
    --token "$INFISICAL_RUNTIME_TOKEN" \
    --projectId "$INFISICAL_PROJECT_ID" \
    --env "$INFISICAL_ENV_EFFECTIVE" \
    --path "$INFISICAL_PATH_EFFECTIVE" \
    -- env BACKUP_INFISICAL_WRAPPED=1 \
    /app/scripts/backup-openclaw-data-to-r2.sh
}

ensure_infisical_injection_if_needed

R2_ENDPOINT="${R2_ENDPOINT:-}"
R2_BUCKET="${R2_BUCKET:-}"
R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-}"
R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-}"
RESTIC_PASSWORD="${RESTIC_PASSWORD:-}"

[ -n "$R2_ENDPOINT" ] || die "R2_ENDPOINT is required"
[ -n "$R2_BUCKET" ] || die "R2_BUCKET is required"
[ -n "$R2_ACCESS_KEY_ID" ] || die "R2_ACCESS_KEY_ID is required"
[ -n "$R2_SECRET_ACCESS_KEY" ] || die "R2_SECRET_ACCESS_KEY is required"
[ -n "$RESTIC_PASSWORD" ] || die "RESTIC_PASSWORD is required"

BACKUP_DIR="${BACKUP_DIR:-/data}"
[ -d "$BACKUP_DIR" ] || die "BACKUP_DIR does not exist: $BACKUP_DIR"

RESOURCE_UUID="${COOLIFY_RESOURCE_UUID:-unknown}"
R2_PREFIX="${R2_PREFIX:-coolify/openclaw-data/${RESOURCE_UUID}}"
RESTIC_TAG="${RESTIC_TAG:-openclaw-data}"

KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-6}"

export RESTIC_PASSWORD
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

R2_PREFIX_STRIPPED="${R2_PREFIX#/}"
if [ -n "$R2_PREFIX_STRIPPED" ]; then
  export RESTIC_REPOSITORY="s3:${R2_ENDPOINT%/}/${R2_BUCKET}/${R2_PREFIX_STRIPPED}"
else
  # Repo at bucket root.
  export RESTIC_REPOSITORY="s3:${R2_ENDPOINT%/}/${R2_BUCKET}"
fi

RESTIC_OPTS=(
  # R2 path-style bucket lookup
  --option "s3.bucket-lookup=path"
)

echo "[backup] repo: $RESTIC_REPOSITORY"
echo "[backup] dir:  $BACKUP_DIR"
echo "[backup] tag:  $RESTIC_TAG"

if ! restic snapshots "${RESTIC_OPTS[@]}" >/dev/null 2>&1; then
  echo "[backup] initializing restic repository..."
  restic init "${RESTIC_OPTS[@]}"
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"

echo "[backup] running backup..."
restic backup "${RESTIC_OPTS[@]}" \
  --tag "$RESTIC_TAG" \
  --tag "resource=${RESOURCE_UUID}" \
  --tag "ts=${TS}" \
  "$BACKUP_DIR"

echo "[backup] retention (daily=$KEEP_DAILY weekly=$KEEP_WEEKLY monthly=$KEEP_MONTHLY)..."
restic forget "${RESTIC_OPTS[@]}" \
  --tag "$RESTIC_TAG" \
  --keep-daily "$KEEP_DAILY" \
  --keep-weekly "$KEEP_WEEKLY" \
  --keep-monthly "$KEEP_MONTHLY" \
  --prune

echo "[backup] done"
