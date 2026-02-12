FROM python:3.12-slim

WORKDIR /app

# Keep image minimal but usable (certs + curl helpful for debugging)
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*

# Install the Google Workspace MCP server (PyPI: workspace-mcp)
# Pin to a known-good version that includes OAuth callback + well-known endpoints.
RUN pip install --no-cache-dir "workspace-mcp==1.4.7"

ENV WORKSPACE_MCP_PORT=8000
ENV PORT=8000

EXPOSE 8000

# Use a shell form so env vars like TOOL_TIER/TOOLS can expand into args (TOOLS splits on spaces).
# NOTE: The `workspace-mcp` CLI binds/ports via env (PORT/WORKSPACE_MCP_PORT); it doesn't accept --host/--port flags.
CMD sh -lc 'workspace-mcp --transport streamable-http ${TOOL_TIER:+--tool-tier "$TOOL_TIER"} ${TOOLS:+--tools $TOOLS}'
