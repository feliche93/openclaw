#!/usr/bin/env bash
set -euo pipefail

# Restore a restic snapshot from Cloudflare R2 into Coolify-managed volumes.
# Default mode is intentionally cautious: it requires empty destination volumes.
#
# Usage:
#   ./restore-openclaw-volumes-from-r2.sh <coolify_resource_uuid> <snapshot_id|latest>
#
# Required env:
#   R2_ENDPOINT
#   R2_BUCKET
#   R2_ACCESS_KEY_ID
#   R2_SECRET_ACCESS_KEY
#   RESTIC_PASSWORD
#
# Optional env:
#   R2_PREFIX        default: coolify/openclaw/<resource_uuid>
#   RESTIC_IMAGE     default: restic/restic:latest
#   RESTORE_MODE     default: safe
#     - safe: requires the destination volume to be empty
#     - overwrite: restores into existing contents (may leave stale files)

die() { echo "[restore] ERROR: $*" >&2; exit 1; }

RESOURCE_UUID="${1:-${COOLIFY_RESOURCE_UUID:-}}"
SNAPSHOT="${2:-}"
[ -n "$RESOURCE_UUID" ] || die "missing Coolify resource uuid (arg1 or COOLIFY_RESOURCE_UUID)"
[ -n "$SNAPSHOT" ] || die "missing snapshot id (arg2), use 'latest' or a snapshot hash"

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
RESTORE_MODE="${RESTORE_MODE:-safe}"

OPENCLAW_VOL="${RESOURCE_UUID}_openclaw-data"
BROWSER_VOL="${RESOURCE_UUID}_browser-data"

docker volume inspect "$OPENCLAW_VOL" >/dev/null 2>&1 || die "docker volume not found: $OPENCLAW_VOL"
docker volume inspect "$BROWSER_VOL" >/dev/null 2>&1 || die "docker volume not found: $BROWSER_VOL"

RESTIC_REPOSITORY="s3:${R2_ENDPOINT%/}/${R2_BUCKET}/${R2_PREFIX#/}"

RESTIC_ENV=(
  -e "RESTIC_REPOSITORY=$RESTIC_REPOSITORY"
  -e "RESTIC_PASSWORD=$RESTIC_PASSWORD"
  -e "AWS_ACCESS_KEY_ID=$R2_ACCESS_KEY_ID"
  -e "AWS_SECRET_ACCESS_KEY=$R2_SECRET_ACCESS_KEY"
  -e "AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}"
)

RESTIC_OPTS=(-o "s3.bucket-lookup=path")

echo "[restore] resource: $RESOURCE_UUID"
echo "[restore] repo: $RESTIC_REPOSITORY"
echo "[restore] snapshot: $SNAPSHOT"
echo "[restore] mode: $RESTORE_MODE"

check_empty() {
  local vol="$1"
  # Busybox find counts entries; ignore '.'.
  docker run --rm -v "${vol}:/dst" alpine:3.20 sh -lc \
    'set -e; n=$(find /dst -mindepth 1 -maxdepth 2 2>/dev/null | wc -l | tr -d " "); echo "$n"' \
    | awk '{exit !($1==0)}'
}

if [ "$RESTORE_MODE" = "safe" ]; then
  echo "[restore] checking destination volumes are empty..."
  check_empty "$OPENCLAW_VOL" || die "volume not empty: $OPENCLAW_VOL (set RESTORE_MODE=overwrite if intended)"
  check_empty "$BROWSER_VOL" || die "volume not empty: $BROWSER_VOL (set RESTORE_MODE=overwrite if intended)"
fi

# The snapshot contains paths like: src/openclaw-data/** and src/browser-data/**
restore_volume_from_snapshot_subdir() {
  local vol="$1"      # docker volume name
  local subdir="$2"   # openclaw-data or browser-data

  echo "[restore] restoring subdir=$subdir into volume=$vol ..."

  # 1) Restore into a staging dir inside the volume.
  docker run --rm \
    "${RESTIC_ENV[@]}" \
    -v "${vol}:/dst" \
    "$RESTIC_IMAGE" restore "${RESTIC_OPTS[@]}" "$SNAPSHOT" \
      --target "/dst/__restic_restore" \
      --include "src/${subdir}/**"

  # 2) Apply staging to volume root.
  docker run --rm -v "${vol}:/dst" alpine:3.20 sh -lc "
    set -e
    src=\"/dst/__restic_restore/src/${subdir}\"
    [ -d \"\$src\" ] || { echo \"[restore] ERROR: expected restored dir missing: \$src\" >&2; exit 1; }

    if [ \"$RESTORE_MODE\" = \"overwrite\" ]; then
      # Remove everything except the staging dir.
      find /dst -mindepth 1 -maxdepth 1 ! -name '__restic_restore' -exec rm -rf {} +
    fi

    # Copy restored contents into volume root.
    cp -a \"\$src/.\" /dst/
    rm -rf /dst/__restic_restore
  "
}

restore_volume_from_snapshot_subdir "$OPENCLAW_VOL" "openclaw-data"
restore_volume_from_snapshot_subdir "$BROWSER_VOL" "browser-data"

echo "[restore] restore completed."
