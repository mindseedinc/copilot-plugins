#!/usr/bin/env bash
# Scaffold a Debian 13 + Apache + PHP + MySQL dev container into a project.
# Compatible with bash 3.2 (macOS) and later.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"

DEFAULT_PHP_VERSION="8.5"
DEFAULT_MYSQL_VERSION="26.7"

usage() {
    cat <<'EOF'
Usage: create-devcontainer.sh [options] [PROJECT_DIR]

Creates PROJECT_DIR/.devcontainer (default: current directory) with:
  - app: Debian 13 (trixie), Apache 2.4, latest PHP + Composer + Xdebug
  - db:  MySQL (official image)

Options:
  --php VERSION        PHP major.minor (default: latest stable from php.net)
  --mysql TAG          MySQL image tag (default: latest numeric tag on Docker Hub)
  --docroot PATH       Web root relative to the project (default: "public" if
                       public/index.php exists, otherwise the project root)
  --name NAME          Project name (default: project folder name)
  --db-name NAME       Database name (default: app)
  --db-user USER       Database user (default: app)
  --db-password PASS   Database user password (default: app)
  --db-root-password P MySQL root password (default: root)
  --offline            Do not query php.net/Docker Hub; use built-in defaults
  --force              Overwrite an existing .devcontainer directory
  --open               Open the project in VS Code inside the dev container
                       (requires the `code` CLI and the Dev Containers extension)
  -h, --help           Show this help
EOF
}

die() { echo "error: $*" >&2; exit 1; }
info() { echo "$*" >&2; }

PROJECT_DIR=""
PHP_VERSION=""
MYSQL_VERSION=""
DOCROOT=""
DOCROOT_SET=0
PROJECT_NAME=""
DB_NAME="app"
DB_USER="app"
DB_PASSWORD="app"
DB_ROOT_PASSWORD="root"
OFFLINE=0
FORCE=0
OPEN=0

need_value() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --php) need_value "$@"; PHP_VERSION="$2"; shift 2 ;;
        --mysql) need_value "$@"; MYSQL_VERSION="$2"; shift 2 ;;
        --docroot) [ $# -ge 2 ] || die "--docroot requires a value"; DOCROOT="$2"; DOCROOT_SET=1; shift 2 ;;
        --name) need_value "$@"; PROJECT_NAME="$2"; shift 2 ;;
        --db-name) need_value "$@"; DB_NAME="$2"; shift 2 ;;
        --db-user) need_value "$@"; DB_USER="$2"; shift 2 ;;
        --db-password) need_value "$@"; DB_PASSWORD="$2"; shift 2 ;;
        --db-root-password) need_value "$@"; DB_ROOT_PASSWORD="$2"; shift 2 ;;
        --offline) OFFLINE=1; shift ;;
        --force) FORCE=1; shift ;;
        --open) OPEN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; [ $# -gt 0 ] && { PROJECT_DIR="$1"; shift; }; break ;;
        -*) die "unknown option: $1 (see --help)" ;;
        *) [ -z "$PROJECT_DIR" ] || die "only one PROJECT_DIR may be given"; PROJECT_DIR="$1"; shift ;;
    esac
done
[ $# -eq 0 ] || die "unexpected arguments: $*"

PROJECT_DIR="${PROJECT_DIR:-$PWD}"
[ -d "$PROJECT_DIR" ] || die "project directory not found: $PROJECT_DIR"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
[ -d "$TEMPLATE_DIR" ] || die "templates not found: $TEMPLATE_DIR"

# --- Resolve latest versions -------------------------------------------------

fetch() { curl -fsSL --max-time 15 "$1" 2>/dev/null; }

latest_php() {
    # php.net lists the newest stable release of PHP 8 as "version":"8.x.y".
    fetch 'https://www.php.net/releases/?json&version=8' \
        | grep -oE '"version":"[0-9]+\.[0-9]+\.[0-9]+"' | head -n 1 \
        | grep -oE '[0-9]+\.[0-9]+' | head -n 1
}

latest_mysql() {
    # Highest "major.minor" tag of the official image, e.g. 26.7.
    fetch 'https://hub.docker.com/v2/repositories/library/mysql/tags?page_size=100&ordering=last_updated' \
        | grep -oE '"name":"[0-9]+\.[0-9]+"' | grep -oE '[0-9]+\.[0-9]+' \
        | sort -t. -k1,1n -k2,2n | tail -n 1
}

if [ -z "$PHP_VERSION" ]; then
    [ "$OFFLINE" -eq 1 ] || PHP_VERSION="$(latest_php || true)"
    if [ -z "$PHP_VERSION" ]; then
        PHP_VERSION="$DEFAULT_PHP_VERSION"
        [ "$OFFLINE" -eq 1 ] || info "warning: could not query php.net; using PHP $PHP_VERSION"
    fi
fi
if [ -z "$MYSQL_VERSION" ]; then
    [ "$OFFLINE" -eq 1 ] || MYSQL_VERSION="$(latest_mysql || true)"
    if [ -z "$MYSQL_VERSION" ]; then
        MYSQL_VERSION="$DEFAULT_MYSQL_VERSION"
        [ "$OFFLINE" -eq 1 ] || info "warning: could not query Docker Hub; using MySQL $MYSQL_VERSION"
    fi
fi

# --- Defaults and validation --------------------------------------------------

if [ -z "$PROJECT_NAME" ]; then
    PROJECT_NAME="$(basename "$PROJECT_DIR")"
fi
# Compose project names: lowercase letters, digits, "-" and "_", starting alphanumeric.
PROJECT_NAME="$(printf '%s' "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-' | sed -e 's/^[^a-z0-9]*//' -e 's/-*$//')"
[ -n "$PROJECT_NAME" ] || PROJECT_NAME="project"

if [ "$DOCROOT_SET" -eq 0 ] && [ -f "$PROJECT_DIR/public/index.php" ]; then
    DOCROOT="public"
fi
DOCROOT="$(printf '%s' "$DOCROOT" | sed -e 's#^\./##' -e 's#^/*##' -e 's#/*$##')"

matches() { printf '%s' "$1" | grep -Eq "$2"; }

matches "$PHP_VERSION" '^[0-9]+\.[0-9]+$' || die "--php must look like 8.5 (got '$PHP_VERSION')"
matches "$MYSQL_VERSION" '^[A-Za-z0-9][A-Za-z0-9._-]*$' || die "invalid --mysql tag '$MYSQL_VERSION'"
if [ -n "$DOCROOT" ]; then
    matches "$DOCROOT" '^[A-Za-z0-9._/-]+$' || die "--docroot may only contain letters, digits, '.', '_', '-' and '/'"
    if matches "/$DOCROOT/" '/\.\.?/'; then die "--docroot must stay inside the project"; fi
fi
for pair in "db-name:$DB_NAME" "db-user:$DB_USER"; do
    matches "${pair#*:}" '^[A-Za-z0-9_]{1,32}$' || die "--${pair%%:*} must be 1-32 letters, digits or '_'"
done
for pair in "db-password:$DB_PASSWORD" "db-root-password:$DB_ROOT_PASSWORD"; do
    matches "${pair#*:}" '^[A-Za-z0-9._@%+=:,-]+$' \
        || die "--${pair%%:*} may only contain letters, digits and ._@%+=:,-"
done
[ "$DB_USER" != "root" ] || die "--db-user cannot be 'root'; use --db-root-password for root"

if [ -n "$DOCROOT" ]; then
    CONTAINER_DOCROOT="/workspace/$DOCROOT"
    [ -d "$PROJECT_DIR/$DOCROOT" ] || info "warning: web root '$DOCROOT' does not exist yet in $PROJECT_DIR"
else
    CONTAINER_DOCROOT="/workspace"
fi

# --- Write files ---------------------------------------------------------------

DEST="$PROJECT_DIR/.devcontainer"
if [ -e "$DEST" ]; then
    [ "$FORCE" -eq 1 ] || die "$DEST already exists (use --force to overwrite generated files)"
fi
mkdir -p "$DEST/mysql/init"

render() {
    sed -e "s|__PHP_VERSION__|$PHP_VERSION|g" \
        -e "s|__MYSQL_VERSION__|$MYSQL_VERSION|g" \
        -e "s|__DOCROOT__|$CONTAINER_DOCROOT|g" \
        -e "s|__PROJECT_NAME__|$PROJECT_NAME|g" \
        -e "s|__DB_NAME__|$DB_NAME|g" \
        -e "s|__DB_USER__|$DB_USER|g" \
        -e "s|__DB_PASSWORD__|$DB_PASSWORD|g" \
        -e "s|__DB_ROOT_PASSWORD__|$DB_ROOT_PASSWORD|g" \
        "$TEMPLATE_DIR/$1" > "$DEST/$1"
}

for f in devcontainer.json compose.yaml Dockerfile apache-vhost.conf php-dev.ini \
         mysql-client.cnf entrypoint.sh post-create.sh .gitattributes; do
    render "$f"
done
chmod +x "$DEST/entrypoint.sh" "$DEST/post-create.sh"
[ -e "$DEST/mysql/init/.gitkeep" ] || : > "$DEST/mysql/init/.gitkeep"

cat >&2 <<EOF
Created $DEST
  Debian 13 (trixie) + Apache 2.4 + PHP $PHP_VERSION + Composer + Xdebug
  MySQL $MYSQL_VERSION (service "db", database "$DB_NAME", user "$DB_USER")
  Web root: $CONTAINER_DOCROOT
EOF

if [ "$OPEN" -eq 1 ]; then
    command -v code >/dev/null 2>&1 \
        || die "'code' CLI not found; in VS Code run 'Shell Command: Install 'code' command in PATH'"
    # Dev Containers URI: the host folder path, hex-encoded.
    hex="$(printf '%s' "$PROJECT_DIR" | od -An -tx1 | tr -d ' \n')"
    info "Opening VS Code in the dev container (first build takes a few minutes)..."
    code --folder-uri "vscode-remote://dev-container+${hex}/workspace"
else
    info ""
    info "Next: open $PROJECT_DIR in VS Code and choose \"Reopen in Container\""
    info "      (or rerun with --open to launch it directly)."
fi
