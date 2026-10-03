#!/usr/bin/env bash
# Workspace-specific setup for the plugins in tools/ (runs after post-create.sh).
set -uo pipefail

# .vscode/settings.json registers plugins by absolute host path; make that path
# resolve inside the container as well.
if [ -n "${LOCAL_WORKSPACE_FOLDER:-}" ] && [ "${LOCAL_WORKSPACE_FOLDER#/}" != "$LOCAL_WORKSPACE_FOLDER" ] \
    && [ ! -e "$LOCAL_WORKSPACE_FOLDER" ]; then
    sudo mkdir -p "$(dirname "$LOCAL_WORKSPACE_FOLDER")" \
        && sudo ln -s /workspace "$LOCAL_WORKSPACE_FOLDER" \
        && echo "workspace: linked $LOCAL_WORKSPACE_FOLDER -> /workspace"
fi

cd /workspace/tools/social-search 2>/dev/null || exit 0

echo "workspace: installing social-search dependencies..."
if [ ! -d node_modules/playwright ]; then
    npm ci --no-audit --no-fund || echo "workspace: npm ci failed; run it in tools/social-search." >&2
fi
# Chromium plus its Debian system libraries (uses sudo for apt).
npx --no-install playwright install --with-deps chromium \
    || echo "workspace: Playwright Chromium install failed; run 'npx playwright install --with-deps chromium'." >&2
