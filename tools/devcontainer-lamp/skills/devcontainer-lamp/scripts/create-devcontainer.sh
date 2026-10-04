#!/usr/bin/env bash
# Scaffold a Debian 13 + Apache + PHP + MySQL dev container into a project.
# Compatible with bash 3.2 (macOS) and later.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/../templates"

DEFAULT_PHP_VERSION="8.5"
DEFAULT_MYSQL_VERSION="26.7"
DEFAULT_APP_DIR="httpdocs"

usage() {
    cat <<'EOF'
Usage: create-devcontainer.sh [options] [PROJECT_DIR]

Creates PROJECT_DIR/.devcontainer (default: current directory) with:
  - app: Debian 13 (trixie), Apache 2.4, latest PHP + Composer + Xdebug
  - db:  MySQL (official image)

Options:
  --php VERSION        PHP major.minor (default: latest stable from php.net)
  --mysql TAG          MySQL image tag (default: latest numeric tag on Docker Hub)
  --port PORT          Pin Apache to a fixed host port (container port 80).
                       Default: no fixed port; VS Code auto-forwards port 80
                       and picks a free host port (avoids conflicts between
                       multiple projects)
  --app-dir NAME       Folder for application files, bound to
                       /var/www/httpdocs (default: httpdocs)
  --docroot PATH       Serve <project>/PATH instead (for layouts like Laravel,
                       where the docroot sits inside the full project; e.g.
                       public). Default: public if public/index.php exists,
                       otherwise the app folder at /var/www/httpdocs
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
matches() { printf '%s' "$1" | grep -Eq "$2"; }

PROJECT_DIR=""
PHP_VERSION=""
MYSQL_VERSION=""
DOCROOT=""
DOCROOT_SET=0
APP_DIR=""
PORT=""
PORT_SET=0
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
        --app-dir) need_value "$@"; APP_DIR="$2"; shift 2 ;;
        --port) need_value "$@"; PORT="$2"; PORT_SET=1; shift 2 ;;
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

if [ -z "$APP_DIR" ]; then
    APP_DIR="$DEFAULT_APP_DIR"
fi
APP_DIR="$(printf '%s' "$APP_DIR" | sed -e 's#^\./##' -e 's#^/*##' -e 's#/*$##')"
matches "$APP_DIR" '^[A-Za-z0-9][A-Za-z0-9._-]*$' \
    || die "--app-dir must be a simple folder name (letters, digits, '.', '_', '-')"
case "$APP_DIR" in
    data|logs|.devcontainer|.git|.vscode) die "--app-dir '$APP_DIR' is reserved" ;;
esac

if [ "$PORT_SET" -eq 1 ]; then
    matches "$PORT" '^[0-9]+$' && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] \
        || die "--port must be a number between 1 and 65535 (got '$PORT')"
    PORTS_KEY="    ports:"
    PORTS_ENTRIES="      - \"${PORT}:80\""
    FORWARD_80=""
    PORT_ATTR="    \"${PORT}:80\": { \"label\": \"Apache\", \"onAutoForward\": \"silent\" },"
    APACHE_PORT_NOTE="pinned to http://localhost:${PORT}"
else
    PORT=""
    PORTS_KEY="    # Apache: no fixed host port; VS Code auto-forwards container port 80."
    PORTS_ENTRIES=""
    FORWARD_80="80,"
    PORT_ATTR="    \"80\": { \"label\": \"Apache\", \"onAutoForward\": \"notify\" },"
    APACHE_PORT_NOTE="auto-forwarded to a free local port (see VS Code's Ports panel)"
fi

if [ "$DOCROOT_SET" -eq 0 ] && [ -f "$PROJECT_DIR/public/index.php" ]; then
    DOCROOT="public"
fi
DOCROOT="$(printf '%s' "$DOCROOT" | sed -e 's#^\./##' -e 's#^/*##' -e 's#/*$##')"

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
    # Framework layout (e.g. Laravel): serve inside the full project mount, so
    # includes like ../vendor still resolve.
    CONTAINER_DOCROOT="/workspace/$DOCROOT"
    WORKSPACE_FOLDER="/workspace"
    [ -d "$PROJECT_DIR/$DOCROOT" ] || info "warning: web root '$DOCROOT' does not exist yet in $PROJECT_DIR"
else
    # Flat layout: application files live in the app folder, bound to /var/www/httpdocs.
    CONTAINER_DOCROOT="/var/www/httpdocs"
    WORKSPACE_FOLDER="/var/www/httpdocs"
fi

# --- Write files ---------------------------------------------------------------

DEST="$PROJECT_DIR/.devcontainer"
if [ -e "$DEST" ]; then
    [ "$FORCE" -eq 1 ] || die "$DEST already exists (use --force to overwrite generated files)"
fi
mkdir -p "$DEST/mysql/init"

# Host-side bind targets: app files and error logs (MySQL data stays in a
# named Docker volume).
mkdir -p "$PROJECT_DIR/$APP_DIR" "$PROJECT_DIR/logs/errors/apache" \
         "$PROJECT_DIR/logs/errors/mysql"
[ -e "$PROJECT_DIR/$APP_DIR/.gitkeep" ] || : > "$PROJECT_DIR/$APP_DIR/.gitkeep"
# Keep generated logs out of git, but keep the .gitignore file itself.
if [ ! -e "$PROJECT_DIR/logs/.gitignore" ]; then
    printf '*\n!.gitignore\n' > "$PROJECT_DIR/logs/.gitignore"
fi

render() {
    sed -e "s|__PHP_VERSION__|$PHP_VERSION|g" \
        -e "s|__MYSQL_VERSION__|$MYSQL_VERSION|g" \
        -e "s|__DOCROOT__|$CONTAINER_DOCROOT|g" \
        -e "s|__PROJECT_NAME__|$PROJECT_NAME|g" \
        -e "s|__DB_NAME__|$DB_NAME|g" \
        -e "s|__DB_USER__|$DB_USER|g" \
        -e "s|__DB_PASSWORD__|$DB_PASSWORD|g" \
        -e "s|__DB_ROOT_PASSWORD__|$DB_ROOT_PASSWORD|g" \
        -e "s|__WORKSPACE_FOLDER__|$WORKSPACE_FOLDER|g" \
        -e "s|__APP_DIR__|$APP_DIR|g" \
        -e "s|__PORT__|$PORT|g" \
        -e "s|__PORTS_KEY__|$PORTS_KEY|g" \
        -e "s|__PORTS_ENTRIES__|$PORTS_ENTRIES|g" \
        -e "s|__FORWARD_80__|$FORWARD_80|g" \
        -e "s|__PORT_ATTR__|$PORT_ATTR|g" \
        -e "s|__APACHE_PORT_NOTE__|$APACHE_PORT_NOTE|g" \
        "$TEMPLATE_DIR/$1" > "$2"
}

for f in devcontainer.json compose.yaml Dockerfile apache-vhost.conf php-dev.ini \
         mysql-client.cnf entrypoint.sh post-create.sh .gitattributes; do
    render "$f" "$DEST/$f"
done
chmod +x "$DEST/entrypoint.sh" "$DEST/post-create.sh"
[ -e "$DEST/mysql/init/.gitkeep" ] || : > "$DEST/mysql/init/.gitkeep"

# .github/copilot-instructions.md: create or update the marked section without
# touching anything the user wrote outside the markers.
INSTRUCTIONS="$PROJECT_DIR/.github/copilot-instructions.md"
SECTION="$(mktemp)"
trap 'rm -f "$SECTION"' EXIT
render copilot-instructions.md "$SECTION"
mkdir -p "$PROJECT_DIR/.github"
if [ ! -e "$INSTRUCTIONS" ]; then
    printf '# Copilot instructions\n' > "$INSTRUCTIONS"
    cat "$SECTION" >> "$INSTRUCTIONS"
elif grep -q 'devcontainer-lamp:begin' "$INSTRUCTIONS"; then
    awk -v section="$SECTION" '
        /devcontainer-lamp:begin/ && !replaced {
            while ((getline line < section) > 0) print line
            close(section)
            replaced = 1
            skip = 1
            next
        }
        /devcontainer-lamp:end/ && skip { skip = 0; next }
        !skip { print }
    ' "$INSTRUCTIONS" > "$INSTRUCTIONS.tmp" && mv "$INSTRUCTIONS.tmp" "$INSTRUCTIONS"
else
    printf '\n' >> "$INSTRUCTIONS"
    cat "$SECTION" >> "$INSTRUCTIONS"
fi
rm -f "$SECTION"; trap - EXIT

cat >&2 <<EOF
Created $DEST
  Debian 13 (trixie) + Apache 2.4 + PHP $PHP_VERSION + Composer + Xdebug
  MySQL $MYSQL_VERSION (service "db", database "$DB_NAME", user "$DB_USER")
  Apache:  ${APACHE_PORT_NOTE}
  Web root: $CONTAINER_DOCROOT
  MySQL data: named volume ${PROJECT_NAME}-devcontainer_mysql-data (persists across rebuilds)
  Host binds:
    $APP_DIR/            -> /var/www/httpdocs (application files)
    logs/errors/apache/  -> /var/log/apache2 (Apache error log)
    logs/errors/mysql/   -> /var/log/mysql (MySQL error log)
  Copilot instructions: .github/copilot-instructions.md (marked section, safe to rerun)
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
