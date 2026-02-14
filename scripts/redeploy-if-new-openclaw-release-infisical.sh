#!/usr/bin/env bash
set -euo pipefail

# Wrapper for Coolify Scheduled Tasks.
#
# Why this exists:
# - Coolify Scheduled Tasks typically run via `docker exec` into the container.
# - Infisical runtime injection (`infisical run ... entrypoint.sh`) injects env
#   vars only for the main process tree, not for later `docker exec` sessions.
# - So scheduled tasks won't see secrets like COOLIFY_API_TOKEN unless we
#   explicitly run the task under `infisical run` here.

if [ -n "${COOLIFY_API_TOKEN:-}" ]; then
  exec /app/scripts/redeploy-if-new-openclaw-release.sh
fi

if [ -z "${INFISICAL_PROJECT_ID:-}" ] || [ -z "${INFISICAL_ENV:-}" ]; then
  echo "[redeploy] ERROR: COOLIFY_API_TOKEN not set, and INFISICAL_* not configured"
  exit 2
fi

INFISICAL_API_URL="${INFISICAL_API_URL:-https://app.infisical.com/api}"
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
  ")"
fi

if [ -z "${INFISICAL_RUNTIME_TOKEN:-}" ]; then
  echo "[redeploy] ERROR: could not acquire Infisical token for scheduled task"
  exit 2
fi

exec infisical run \
  --domain "$INFISICAL_API_URL" \
  --token "$INFISICAL_RUNTIME_TOKEN" \
  --projectId "$INFISICAL_PROJECT_ID" \
  --env "$INFISICAL_ENV" \
  --path "$INFISICAL_PATH_EFFECTIVE" \
  -- /app/scripts/redeploy-if-new-openclaw-release.sh

