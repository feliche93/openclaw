#!/usr/bin/env sh
set -eu

# Optional: inject secrets from Infisical (runtime).
# Re-exec ourselves under `infisical run` so the Node process sees injected env.
if [ -n "${INFISICAL_TOKEN:-}" ] && [ -n "${INFISICAL_PROJECT_ID:-}" ] && [ -z "${INFISICAL_INJECTED:-}" ]; then
  export INFISICAL_INJECTED=1
  INFISICAL_ENV_EFFECTIVE="${INFISICAL_ENV:-prod}"
  INFISICAL_PATH_EFFECTIVE="${INFISICAL_PATH:-/}"
  echo "[camofox-entrypoint] infisical: injecting secrets (env=$INFISICAL_ENV_EFFECTIVE path=$INFISICAL_PATH_EFFECTIVE)"
  exec infisical run \
    --token "$INFISICAL_TOKEN" \
    --projectId "$INFISICAL_PROJECT_ID" \
    --env "$INFISICAL_ENV_EFFECTIVE" \
    --path "$INFISICAL_PATH_EFFECTIVE" \
    -- "$0" "$@"
fi

# Coolify magic env var alias (if you store the value under SERVICE_BASE64_64_CAMOFOX).
if [ -z "${CAMOFOX_API_KEY:-}" ] && [ -n "${SERVICE_BASE64_64_CAMOFOX:-}" ]; then
  export CAMOFOX_API_KEY="$SERVICE_BASE64_64_CAMOFOX"
fi

exec "$@"

