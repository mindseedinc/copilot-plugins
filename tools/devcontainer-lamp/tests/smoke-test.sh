#!/usr/bin/env bash
# End-to-end test: generate a dev container into a temporary project, start it
# with the Dev Containers CLI, and verify Debian 13, PHP, Apache and MySQL.
# Requires Docker and Node.js (npx). Usage: tests/smoke-test.sh [--keep]
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

mkdir -p "$PROJECT/public"
cat > "$PROJECT/public/index.php" <<'PHP'
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
run() { "${DC[@]}" exec --workspace-folder "$PROJECT" bash -lc "$1" 2>/dev/null; }

"$ROOT/create-devcontainer.sh" --name "$NAME" "$PROJECT"
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
check "dotfiles blocked" '^403$' "$(run 'echo secret > public/.env && curl -s -o /dev/null -w "%{http_code}" http://localhost/.env')"

echo "All smoke tests passed."
