#!/usr/bin/env bash
# Convenience wrapper; see skills/devcontainer-lamp/scripts/create-devcontainer.sh.
# Works when symlinked onto PATH (e.g. ln -s "$PWD/create-devcontainer.sh" ~/bin/create-lamp-devcontainer).
set -euo pipefail
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    case "$src" in /*) ;; *) src="$dir/$src" ;; esac
done
root="$(cd -P "$(dirname "$src")" && pwd)"
exec "$root/skills/devcontainer-lamp/scripts/create-devcontainer.sh" "$@"
