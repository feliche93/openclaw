#!/usr/bin/env bash
set -euo pipefail

# Coolify Scheduled Task helper:
# - Compare running OpenClaw version vs latest upstream release.
# - Trigger a Coolify deploy only when a newer version exists.
#
# Required env:
# - COOLIFY_API_TOKEN: Coolify API token (Bearer)
# - COOLIFY_RESOURCE_UUID: UUID of the resource to deploy
#
# Optional env:
# - COOLIFY_API_BASE: e.g. https://app.coolify.io (default) or your self-hosted base URL
# - COOLIFY_FORCE: "true" to force deploy even if same version (default: false)
#
# Notes:
# - This script assumes `openclaw --version` is available in the container.
# - It reads upstream version from GitHub releases: openclaw/openclaw.

COOLIFY_API_BASE="${COOLIFY_API_BASE:-https://app.coolify.io}"
COOLIFY_FORCE="${COOLIFY_FORCE:-false}"

if [ -z "${COOLIFY_API_TOKEN:-}" ]; then
  echo "[redeploy] ERROR: COOLIFY_API_TOKEN is required"
  exit 2
fi
if [ -z "${COOLIFY_RESOURCE_UUID:-}" ]; then
  echo "[redeploy] ERROR: COOLIFY_RESOURCE_UUID is required"
  exit 2
fi

current="$(
  (openclaw --version 2>/dev/null || true) \
    | sed -E 's/^v?([0-9]+\.[0-9]+\.[0-9]+).*$/\1/' \
    | head -n 1
)"

latest="$(
  curl -fsSL https://api.github.com/repos/openclaw/openclaw/releases/latest \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);process.stdout.write(String(j.tag_name||"").replace(/^v/,""));});' \
    | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*$/\1/'
)"

if [ -z "${latest:-}" ]; then
  echo "[redeploy] ERROR: could not determine latest upstream version"
  exit 1
fi
if [ -z "${current:-}" ]; then
  echo "[redeploy] WARN: could not determine current version; will deploy if not forced? deploying anyway."
else
  if [ "${COOLIFY_FORCE}" != "true" ]; then
    cmp="$(
      CURRENT="${current}" LATEST="${latest}" node -e '
        const a = (process.env.CURRENT || "").split(".").map(n => parseInt(n,10));
        const b = (process.env.LATEST || "").split(".").map(n => parseInt(n,10));
        for (let i = 0; i < 3; i++) {
          const av = Number.isFinite(a[i]) ? a[i] : 0;
          const bv = Number.isFinite(b[i]) ? b[i] : 0;
          if (av < bv) { process.stdout.write("-1"); process.exit(0); }
          if (av > bv) { process.stdout.write("1"); process.exit(0); }
        }
        process.stdout.write("0");
      ' 2>/dev/null
    )" || cmp=""
    if [ "${cmp:-}" = "0" ] || [ "${cmp:-}" = "1" ]; then
      echo "[redeploy] Up to date or ahead (current=${current} latest=${latest}); skipping deploy."
      exit 0
    fi
  fi
fi

deploy_url="${COOLIFY_API_BASE%/}/api/v1/deploy?uuid=${COOLIFY_RESOURCE_UUID}&force=${COOLIFY_FORCE}"

echo "[redeploy] Triggering deploy (current=${current:-unknown} latest=${latest} force=${COOLIFY_FORCE})"
curl -fsS -H "Authorization: Bearer ${COOLIFY_API_TOKEN}" "${deploy_url}" >/dev/null
echo "[redeploy] Deploy requested: ${deploy_url}"
