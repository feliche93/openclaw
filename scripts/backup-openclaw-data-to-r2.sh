#!/usr/bin/env bash
set -euo pipefail

# Backup OpenClaw persisted data dir to Cloudflare R2 using restic (S3 backend).
#
# Intended to run INSIDE the OpenClaw container as a Coolify Scheduled Task.
# This backs up the mounted /data volume (OpenClaw state + workspace) only.
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
