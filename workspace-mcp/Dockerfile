FROM python:3.12-slim

WORKDIR /app

# Keep image minimal but usable (certs + curl helpful for debugging)
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*

# Install the Google Workspace MCP server (PyPI: workspace-mcp)
RUN pip install --no-cache-dir workspace-mcp

ENV WORKSPACE_MCP_PORT=8000

EXPOSE 8000

# Use a shell form so env vars like TOOL_TIER/TOOLS can expand into args (TOOLS splits on spaces).
CMD sh -lc 'workspace-mcp --transport streamable-http --host 0.0.0.0 --port "${WORKSPACE_MCP_PORT:-8000}" ${TOOL_TIER:+--tool-tier "$TOOL_TIER"} ${TOOLS:+--tools $TOOLS}'

