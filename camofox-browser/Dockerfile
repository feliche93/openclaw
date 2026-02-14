FROM node:20-slim

# Pinned Camoufox version for reproducible builds
# Update these when upgrading Camoufox
ARG CAMOUFOX_VERSION=135.0.1
ARG CAMOUFOX_RELEASE=beta.24
# Infisical CLI (optional; used for runtime secret injection via INFISICAL_TOKEN)
ARG INFISICAL_VERSION=0.43.48
# BuildKit sets TARGETARCH (amd64/arm64). Default to amd64 naming.
ARG TARGETARCH
ARG CAMOUFOX_URL=

# Install dependencies for Camoufox (Firefox-based)
RUN apt-get update && apt-get install -y \
    # Firefox dependencies
    libgtk-3-0 \
    libdbus-glib-1-2 \
    libxt6 \
    libasound2 \
    libx11-xcb1 \
    libxcomposite1 \
    libxcursor1 \
    libxdamage1 \
    libxfixes3 \
    libxi6 \
    libxrandr2 \
    libxrender1 \
    libxss1 \
    libxtst6 \
    # Fonts
    fonts-liberation \
    fonts-noto-color-emoji \
    fontconfig \
    # Utils
    ca-certificates \
    curl \
    tar \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install Infisical CLI (for optional runtime env injection)
RUN set -eux; \
    arch="${TARGETARCH:-}"; \
    [ -z "$arch" ] && arch="$(uname -m)" || true; \
    case "$arch" in \
      amd64|x86_64) go_arch="amd64" ;; \
      arm64|aarch64) go_arch="arm64" ;; \
      *) echo "Unsupported architecture for infisical: $arch" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/Infisical/cli/releases/download/v${INFISICAL_VERSION}/cli_${INFISICAL_VERSION}_linux_${go_arch}.tar.gz"; \
    curl -fsSL "$url" -o /tmp/infisical.tgz; \
    tar -xzf /tmp/infisical.tgz -C /tmp infisical; \
    install -m 0755 /tmp/infisical /usr/local/bin/infisical; \
    rm -f /tmp/infisical.tgz /tmp/infisical; \
    infisical --version

# Pre-bake Camoufox browser binary into image
# This avoids downloading at runtime and pins the version
# Note: unzip returns exit code 1 for warnings (Unicode filenames), so we use || true and verify
RUN mkdir -p /root/.cache/camoufox \
    && ARCH="x86_64" \
    && [ "${TARGETARCH:-}" = "arm64" ] && ARCH="arm64" || true \
    && URL="${CAMOFOX_URL:-}" \
    && [ -z "$URL" ] && URL="https://github.com/daijro/camoufox/releases/download/v${CAMOUFOX_VERSION}-${CAMOUFOX_RELEASE}/camoufox-${CAMOUFOX_VERSION}-${CAMOUFOX_RELEASE}-lin.${ARCH}.zip" || true \
    && echo "Downloading Camoufox: $URL" \
    && curl -L -o /tmp/camoufox.zip "$URL" \
    && (unzip -q /tmp/camoufox.zip -d /root/.cache/camoufox || true) \
    && rm /tmp/camoufox.zip \
    && chmod -R 755 /root/.cache/camoufox \
    && echo "{\"version\":\"${CAMOUFOX_VERSION}\",\"release\":\"${CAMOUFOX_RELEASE}\"}" > /root/.cache/camoufox/version.json \
    && test -f /root/.cache/camoufox/camoufox-bin && echo "Camoufox installed successfully"

WORKDIR /app

COPY package.json ./
RUN npm install --production

COPY server.js ./
COPY lib/ ./lib/
COPY entrypoint.sh ./entrypoint.sh
RUN chmod +x ./entrypoint.sh

ENV NODE_ENV=production
ENV CAMOFOX_PORT=3000

EXPOSE 3000

ENTRYPOINT ["./entrypoint.sh"]
CMD ["node", "server.js"]
