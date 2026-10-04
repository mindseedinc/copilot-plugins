#!/usr/bin/env bash
# End-to-end test: generate a dev container into a temporary project, start it
# with the Dev Containers CLI, and verify Debian 13, PHP, Apache and MySQL,
# the fixed host port, and the host-side bind mounts (data, logs, app files).
# Requires Docker and Node.js (npx). Usage: tests/smoke-test.sh [--keep]
# Set PINNED_PORT=1 to also publish a fixed host port (default: auto-forward).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

WORK="$(mktemp -d)"
PROJECT="$WORK/lamp-smoke"
NAME="lamp-smoke-$$"
DC=(npx -y @devcontainers/cli)

cleanup() {
    if [ "$KEEP" -eq 0 ]; then
        docker compose -p "${NAME}-devcontainer" down -v --remove-orphans >/dev/null 2>&1 || true
        rm -rf "$WORK"
    else
        echo "Kept $PROJECT (compose project ${NAME}-devcontainer)"
    fi
}
trap cleanup EXIT

# Flat layout: application files in httpdocs/, bound to /var/www/httpdocs.
mkdir -p "$PROJECT/httpdocs"
cat > "$PROJECT/httpdocs/index.php" <<'PHP'
<?php
$pdo = new PDO(
    sprintf('mysql:host=%s;port=%s;dbname=%s', getenv('DB_HOST'), getenv('DB_PORT'), getenv('DB_DATABASE')),
    getenv('DB_USERNAME'),
    getenv('DB_PASSWORD'),
);
$pdo->exec('CREATE TABLE IF NOT EXISTS smoke (id INT PRIMARY KEY)');
$pdo->exec('REPLACE INTO smoke VALUES (1)');
echo 'PHP ', PHP_VERSION, ' | ', php_sapi_name(), ' | MySQL ', $pdo->query('SELECT VERSION()')->fetchColumn(),
    ' | rows ', $pdo->query('SELECT COUNT(*) FROM smoke')->fetchColumn(), "\n";
PHP

fail() { echo "FAIL: $*" >&2; exit 1; }
check() {
    local label="$1" expected="$2" actual="$3"
    printf '%s' "$actual" | grep -Eq "$expected" || fail "$label: expected /$expected/, got: $actual"
    echo "ok - $label: $(printf '%s' "$actual" | head -n 1)"
}
check_file() { [ -s "$2" ] || fail "$1: expected non-empty $2"; echo "ok - $1: $2"; }
run() { "${DC[@]}" exec --workspace-folder "$PROJECT" bash -lc "$1" 2>/dev/null; }

if [ -n "${PINNED_PORT:-}" ] && [ "$(uname)" != "Darwin" ]; then
    if lsof -i :8080 -sTCP:LISTEN >/dev/null 2>&1; then
        fail "host port 8080 is already in use"
    fi
fi

"$ROOT/create-devcontainer.sh" --name "$NAME" ${PINNED_PORT:+--port 8080} "$PROJECT"
"${DC[@]}" up --workspace-folder "$PROJECT" --remove-existing-container >"$WORK/up.log" 2>&1 \
    || { tail -n 60 "$WORK/up.log"; fail "devcontainer up"; }

PHP_EXPECTED="$(grep -oE 'PHP_VERSION: "[0-9.]+"' "$PROJECT/.devcontainer/compose.yaml" | grep -oE '[0-9]+\.[0-9]+')"
MYSQL_EXPECTED="$(grep -oE 'image: mysql:[^ ]+' "$PROJECT/.devcontainer/compose.yaml" | cut -d: -f3)"

check "Debian 13"      'VERSION_ID="13"'               "$(run 'grep VERSION_ID /etc/os-release')"
check "remote user"    '^vscode$'                      "$(run 'whoami')"
check "PHP CLI"        "^PHP ${PHP_EXPECTED//./\\.}\."  "$(run 'php -v')"
check "PHP extensions" 'pdo_mysql.*xdebug|xdebug.*pdo_mysql' "$(run 'php -m | tr "\n" " "')"
check "Composer"       '^Composer version 2\.'         "$(run 'composer --version')"
check "Apache"         'Apache/2\.4\.'                 "$(run 'apache2 -v')"
check "Apache user"    '^vscode'                       "$(run 'ps -o user= -C apache2 | sort | uniq -c | sort -rn | awk "{print \$2}" | head -n1')"
check "MySQL client"   'mysql|mariadb'                 "$(run 'mysql --version')"
check "MySQL server"   "^${MYSQL_EXPECTED//./\\.}"     "$(run 'mysql -N -e "SELECT VERSION()"')"
check "mysqldump"      'CREATE TABLE `smoke`'          "$(run 'curl -fsS http://localhost/ >/dev/null && mysqldump --no-tablespaces "$DB_DATABASE" smoke')"
check "Apache + PHP + MySQL" "PHP ${PHP_EXPECTED//./\\.}.* apache2handler .*MySQL ${MYSQL_EXPECTED//./\\.}.* rows 1" \
    "$(run 'curl -fsS http://localhost/')"
check "dotfiles blocked" '^403$' "$(run 'echo secret > .env && curl -s -o /dev/null -w "%{http_code}" http://localhost/.env')"

# Port behavior: default is VS Code auto-forward (no published host port).
if [ -n "${PINNED_PORT:-}" ]; then
    check "host port 8080" "PHP ${PHP_EXPECTED//./\\.}.* apache2handler" "$(curl -fsS http://localhost:8080/)"
else
    grep -q 'ports:' "$PROJECT/.devcontainer/compose.yaml" \
        && fail "default config must not publish a fixed host port"
    echo "ok - default config auto-forwards port 80 (no 'ports:' in compose)"
fi

# MySQL data persists in a named volume.
docker volume inspect "${NAME}-devcontainer_mysql-data" >/dev/null 2>&1 \
    || fail "MySQL named volume ${NAME}-devcontainer_mysql-data not found"
echo "ok - MySQL named volume: ${NAME}-devcontainer_mysql-data"

# Host-side bind mounts exist and receive data.
check_file "Apache error log bind" "$PROJECT/logs/errors/apache/error.log"
check_file "MySQL error log bind"  "$PROJECT/logs/errors/mysql/error.log"

# Framework layout (public/index.php) keeps docroot inside the project mount.
FW="$WORK/fw"
mkdir -p "$FW/public" && echo '<?php echo "fw";' > "$FW/public/index.php"
"$ROOT/create-devcontainer.sh" --offline --force --name "${NAME}-fw" "$FW" >/dev/null 2>&1
check "framework docroot" '/workspace/public'  "$(grep APACHE_DOCUMENT_ROOT "$FW/.devcontainer/compose.yaml" | cut -d'"' -f2)"
check "framework workspaceFolder" '^/workspace$' "$(grep -o '"workspaceFolder": "[^"]*"' "$FW/.devcontainer/devcontainer.json" | cut -d'"' -f4)"
check "framework volume" 'mysql-data:' "$(grep -A1 '^volumes:' "$FW/.devcontainer/compose.yaml" | tail -1 | tr -d ' ')"

# .github/copilot-instructions.md: created, rendered, idempotent, and merge-safe.
INSTR="$PROJECT/.github/copilot-instructions.md"
check "instructions file"    'devcontainer-lamp:begin' "$(cat "$INSTR" 2>/dev/null)"
check "instructions project" "${NAME}-devcontainer_mysql-data" "$(cat "$INSTR")"
check "instructions port note" 'auto-forwarded to a free local port' "$(sed -n 's/.*Port 80 is \(.*\)\.$/\1/p' "$INSTR")"
printf 'Custom note.\n' >> "$INSTR"
"$ROOT/create-devcontainer.sh" --offline --force --port 9999 "$PROJECT" >/dev/null 2>&1
[ "$(grep -c 'devcontainer-lamp:begin' "$INSTR")" = "1" ] || fail "instructions section duplicated on rerun"
grep -q 'Custom note\.' "$INSTR" || fail "user content outside markers was lost"
grep -q 'localhost:9999' "$INSTR" || fail "marked section not updated on rerun"
echo "ok - instructions rerun updates section, keeps user content"

echo "All smoke tests passed."

echo "All smoke tests passed."
