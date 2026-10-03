#!/usr/bin/env bash
# Start Apache in the background, then run the container command.
set -euo pipefail

if [ ! -d "${APACHE_DOCUMENT_ROOT:-/workspace}" ]; then
    echo "devcontainer: APACHE_DOCUMENT_ROOT '${APACHE_DOCUMENT_ROOT}' does not exist; Apache may return 404." >&2
fi

if [ "$(id -u)" -eq 0 ]; then
    apache2ctl start || echo "devcontainer: Apache failed to start; see 'apache2ctl configtest'." >&2
else
    sudo --preserve-env=APACHE_DOCUMENT_ROOT apache2ctl start \
        || echo "devcontainer: Apache failed to start; see 'apache2ctl configtest'." >&2
fi

exec "$@"
