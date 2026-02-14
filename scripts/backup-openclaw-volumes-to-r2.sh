#!/usr/bin/env bash
set -euo pipefail

# Backup Coolify-managed OpenClaw volumes to Cloudflare R2 using restic (S3 backend).
#
# Runs on the Coolify host (needs Docker). Does NOT require restic installed locally.
#
# Usage:
#   ./backup-openclaw-volumes-to-r2.sh <coolify_resource_uuid>
#
# Required env:
#   R2_ENDPOINT               e.g. https://<accountid>.r2.cloudflarestorage.com
#   R2_BUCKET                 e.g. my-backups
#   R2_ACCESS_KEY_ID
#   R2_SECRET_ACCESS_KEY
#   RESTIC_PASSWORD           encryption password (store safely)
#
# Optional env:
#   R2_PREFIX                 default: coolify/openclaw/<resource_uuid>
#   RESTIC_IMAGE              default: restic/restic:latest
#   RESTIC_TAG                default: openclaw
#   KEEP_DAILY                default: 7
#   KEEP_WEEKLY               default: 4
#   KEEP_MONTHLY              default: 6
#   INCLUDE_COOLIFY_APP_DIR    default: true (backs up /data/coolify/applications/<uuid>)
#
# Notes:
# - This backs up:
#     - Docker volume: <uuid>_openclaw-data   (mounted at /src/openclaw-data)
#     - Docker volume: <uuid>_browser-data    (mounted at /src/browser-data)
#     - Optional: /data/coolify/applications/<uuid> (compose + config files)
# - If you delete the Coolify app WITH volume deletion, these volumes are gone.

die() { echo "[backup] ERROR: $*" >&2; exit 1; }

RESOURCE_UUID="${1:-${COOLIFY_RESOURCE_UUID:-}}"
[ -n "$RESOURCE_UUID" ] || die "missing Coolify resource uuid (arg1 or COOLIFY_RESOURCE_UUID)"

command -v docker >/dev/null 2>&1 || die "docker not found on PATH"

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

R2_PREFIX="${R2_PREFIX:-coolify/openclaw/${RESOURCE_UUID}}"
RESTIC_IMAGE="${RESTIC_IMAGE:-restic/restic:latest}"
RESTIC_TAG="${RESTIC_TAG:-openclaw}"

KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-6}"

INCLUDE_COOLIFY_APP_DIR="${INCLUDE_COOLIFY_APP_DIR:-true}"

# Coolify naming pattern (observed on the host):
OPENCLAW_VOL="${RESOURCE_UUID}_openclaw-data"
BROWSER_VOL="${RESOURCE_UUID}_browser-data"

echo "[backup] resource: $RESOURCE_UUID"
echo "[backup] volumes: $OPENCLAW_VOL, $BROWSER_VOL"

docker volume inspect "$OPENCLAW_VOL" >/dev/null 2>&1 || die "docker volume not found: $OPENCLAW_VOL"
docker volume inspect "$BROWSER_VOL" >/dev/null 2>&1 || die "docker volume not found: $BROWSER_VOL"

COOLIFY_APP_DIR="/data/coolify/applications/${RESOURCE_UUID}"
COOLIFY_APP_MOUNT=()
if [ "$INCLUDE_COOLIFY_APP_DIR" = "true" ] && [ -d "$COOLIFY_APP_DIR" ]; then
  echo "[backup] including coolify app dir: $COOLIFY_APP_DIR"
  COOLIFY_APP_MOUNT=(-v "$COOLIFY_APP_DIR:/src/coolify-app:ro")
else
  echo "[backup] skipping coolify app dir (INCLUDE_COOLIFY_APP_DIR=$INCLUDE_COOLIFY_APP_DIR, exists=$( [ -d "$COOLIFY_APP_DIR" ] && echo yes || echo no ))"
fi

# restic S3 repository with custom endpoint: s3:https://endpoint/bucket/prefix
RESTIC_REPOSITORY="s3:${R2_ENDPOINT%/}/${R2_BUCKET}/${R2_PREFIX#/}"

RESTIC_ENV=(
  -e "RESTIC_REPOSITORY=$RESTIC_REPOSITORY"
  -e "RESTIC_PASSWORD=$RESTIC_PASSWORD"
  -e "AWS_ACCESS_KEY_ID=$R2_ACCESS_KEY_ID"
  -e "AWS_SECRET_ACCESS_KEY=$R2_SECRET_ACCESS_KEY"
  -e "AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}"
)

RESTIC_OPTS=(
  # Force path-style lookup; R2 is S3-compatible but not AWS.
  -o "s3.bucket-lookup=path"
)

run_restic() {
  docker run --rm \
    "${RESTIC_ENV[@]}" \
    -v "${OPENCLAW_VOL}:/src/openclaw-data:ro" \
    -v "${BROWSER_VOL}:/src/browser-data:ro" \
    "${COOLIFY_APP_MOUNT[@]}" \
    "$RESTIC_IMAGE" "$@"
}

echo "[backup] restic repo: $RESTIC_REPOSITORY"

# Initialize repo if needed
if ! run_restic snapshots "${RESTIC_OPTS[@]}" >/dev/null 2>&1; then
  echo "[backup] initializing restic repository..."
  run_restic init "${RESTIC_OPTS[@]}"
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
HOST_TAG="host=$(hostname 2>/dev/null || echo unknown)"

echo "[backup] running backup..."
run_restic backup "${RESTIC_OPTS[@]}" \
  --tag "$RESTIC_TAG" \
  --tag "resource=${RESOURCE_UUID}" \
  --tag "$HOST_TAG" \
  --tag "ts=${TS}" \
  /src

echo "[backup] applying retention (daily=$KEEP_DAILY weekly=$KEEP_WEEKLY monthly=$KEEP_MONTHLY)..."
run_restic forget "${RESTIC_OPTS[@]}" \
  --tag "$RESTIC_TAG" \
  --keep-daily "$KEEP_DAILY" \
  --keep-weekly "$KEEP_WEEKLY" \
  --keep-monthly "$KEEP_MONTHLY" \
  --prune

echo "[backup] latest snapshots:"
run_restic snapshots "${RESTIC_OPTS[@]}" --tag "$RESTIC_TAG" | tail -n 25 || true

