#!/usr/bin/env bash
set -euo pipefail

# Restore OpenClaw persisted data dir from Cloudflare R2 using restic (S3 backend).
#
# Intended to run INSIDE the OpenClaw container (e.g., a one-off Coolify command
# or Scheduled Task), typically while the app is stopped.
#
# It restores the snapshot of BACKUP_DIR (default /data) into the mounted BACKUP_DIR
# by restoring into a staging dir then copying into place.
#
# Usage:
#   SNAPSHOT=latest /app/scripts/restore-openclaw-data-from-r2.sh
#
# Required env:
#   R2_ENDPOINT
#   R2_BUCKET
#   R2_ACCESS_KEY_ID
#   R2_SECRET_ACCESS_KEY
#   RESTIC_PASSWORD
#   SNAPSHOT                 e.g. "latest" or a snapshot hash
#
# Optional env:
#   BACKUP_DIR               default: /data
#   R2_PREFIX                default: coolify/openclaw-data/<COOLIFY_RESOURCE_UUID> (or "/" for bucket root)
#   RESTORE_MODE             default: safe
#     - safe: requires BACKUP_DIR to be empty (prevents accidental clobber)
#     - overwrite: wipes BACKUP_DIR before restoring

die() { echo "[restore] ERROR: $*" >&2; exit 1; }

command -v restic >/dev/null 2>&1 || die "restic not found (image must include it)"

R2_ENDPOINT="${R2_ENDPOINT:-}"
R2_BUCKET="${R2_BUCKET:-}"
R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-}"
R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-}"
RESTIC_PASSWORD="${RESTIC_PASSWORD:-}"
SNAPSHOT="${SNAPSHOT:-}"

[ -n "$R2_ENDPOINT" ] || die "R2_ENDPOINT is required"
[ -n "$R2_BUCKET" ] || die "R2_BUCKET is required"
[ -n "$R2_ACCESS_KEY_ID" ] || die "R2_ACCESS_KEY_ID is required"
[ -n "$R2_SECRET_ACCESS_KEY" ] || die "R2_SECRET_ACCESS_KEY is required"
[ -n "$RESTIC_PASSWORD" ] || die "RESTIC_PASSWORD is required"
[ -n "$SNAPSHOT" ] || die "SNAPSHOT is required (e.g. latest)"

BACKUP_DIR="${BACKUP_DIR:-/data}"
[ -d "$BACKUP_DIR" ] || die "BACKUP_DIR does not exist: $BACKUP_DIR"

RESOURCE_UUID="${COOLIFY_RESOURCE_UUID:-unknown}"
R2_PREFIX="${R2_PREFIX:-coolify/openclaw-data/${RESOURCE_UUID}}"
RESTORE_MODE="${RESTORE_MODE:-safe}"

export RESTIC_PASSWORD
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

R2_PREFIX_STRIPPED="${R2_PREFIX#/}"
if [ -n "$R2_PREFIX_STRIPPED" ]; then
  export RESTIC_REPOSITORY="s3:${R2_ENDPOINT%/}/${R2_BUCKET}/${R2_PREFIX_STRIPPED}"
else
  export RESTIC_REPOSITORY="s3:${R2_ENDPOINT%/}/${R2_BUCKET}"
fi

RESTIC_OPTS=(--option "s3.bucket-lookup=path")

backup_basename="$(basename "$BACKUP_DIR")"
staging="${BACKUP_DIR}/__restic_restore"

echo "[restore] repo: $RESTIC_REPOSITORY"
echo "[restore] snapshot: $SNAPSHOT"
echo "[restore] backup_dir: $BACKUP_DIR"
echo "[restore] mode: $RESTORE_MODE"

is_empty_dir() {
  local d="$1"
  # Consider a directory "empty" if it has no entries at depth 1.
  [ "$(find "$d" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" = "0" ]
}

if [ "$RESTORE_MODE" = "safe" ]; then
  is_empty_dir "$BACKUP_DIR" || die "BACKUP_DIR is not empty ($BACKUP_DIR). Stop app and empty it or set RESTORE_MODE=overwrite"
elif [ "$RESTORE_MODE" = "overwrite" ]; then
  # Remove everything except our staging dir (created below).
  :
else
  die "invalid RESTORE_MODE: $RESTORE_MODE (expected safe|overwrite)"
fi

rm -rf "$staging"
mkdir -p "$staging"

echo "[restore] restoring into staging..."
restic restore "${RESTIC_OPTS[@]}" "$SNAPSHOT" \
  --target "$staging" \
  --include "${BACKUP_DIR#/}/**"

restored_path="${staging}/${backup_basename}"
[ -d "$restored_path" ] || die "expected restored dir missing: $restored_path"

if [ "$RESTORE_MODE" = "overwrite" ]; then
  echo "[restore] wiping destination..."
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 ! -name "__restic_restore" -exec rm -rf {} +
fi

echo "[restore] applying restored contents..."
cp -a "${restored_path}/." "$BACKUP_DIR/"
rm -rf "$staging"

echo "[restore] restore completed"

