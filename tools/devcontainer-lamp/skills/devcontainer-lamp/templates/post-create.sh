#!/usr/bin/env bash
# Runs once after the dev container is created.
set -euo pipefail

# Application files live at the Apache document root (or /workspace for
# framework layouts where the docroot is inside the full project).
cd "${APACHE_DOCUMENT_ROOT:-/var/www/httpdocs}" 2>/dev/null || cd /workspace

# Let `mysql` and `mysqldump` connect to the "db" service without arguments.
if [ ! -e "$HOME/.my.cnf" ]; then
    printf '[client]\nuser=%s\npassword=%s\n\n[mysql]\ndatabase=%s\n' \
        "$DB_USERNAME" "$DB_PASSWORD" "$DB_DATABASE" > "$HOME/.my.cnf"
    chmod 600 "$HOME/.my.cnf"
fi

if [ -f composer.json ] && [ ! -d vendor ]; then
    echo "devcontainer: installing Composer dependencies..."
    composer install --no-interaction --prefer-dist || echo "devcontainer: composer install failed; run it manually." >&2
fi

echo
echo "Dev container ready:"
php -v | head -n 1
apache2 -v | head -n 1
mysql --version
echo "  Web root : ${APACHE_DOCUMENT_ROOT}"
echo "  Apache   : http://localhost (forwarded port 80)"
echo "  MySQL    : host=${DB_HOST} port=${DB_PORT} db=${DB_DATABASE} user=${DB_USERNAME}"
