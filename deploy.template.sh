#!/bin/bash
set -e

# ─────────────────────────────────────────────────────────────
# CONFIGURATION — edit these before deploying
# ─────────────────────────────────────────────────────────────
APP_DIR="/var/www/HOSTNAME"
APP_USER="cem"
APP_GROUP="www-data"

# Framework: laravel | codeigniter | symfony | cakephp | none
FRAMEWORK="none"
# ─────────────────────────────────────────────────────────────

# chmod a directory only if it exists; skip with a notice otherwise
perm() {
    if [ -d "$1" ]; then
        sudo chmod -R 775 "$1"
    else
        echo "  [SKIP] $1 not found — skipping"
    fi
}

# Read a key from an .env file and strip surrounding quotes/whitespace (handles "KEY=val" and "KEY = val")
_env_val() { grep -m1 "^${1}[[:space:]]*=" "${2}" | cut -d= -f2- | sed "s/^[[:space:]]*//;s/^['\"]//;s/['\"]$//"; }

# Returns 0 if DB is reachable, 1 if unreachable, 2 if check could not run
db_reachable() {
    if ! command -v mysql &>/dev/null; then
        echo "  [DB] mysql client not found — skipping connectivity check"
        return 2
    fi

    local env_file="$APP_DIR/.env"
    if [ ! -f "$env_file" ]; then
        echo "  [DB] No .env file — assuming no database, skipping migrations"
        return 1
    fi

    local host port user pass dbname

    # Laravel / CodeIgniter 4 (DB_* keys)
    host=$(_env_val   DB_HOST     "$env_file")
    port=$(_env_val   DB_PORT     "$env_file")
    user=$(_env_val   DB_USERNAME "$env_file")
    pass=$(_env_val   DB_PASSWORD "$env_file")
    dbname=$(_env_val DB_DATABASE "$env_file")

    # CodeIgniter 4 alternative key names
    [ -z "$host" ]   && host=$(_env_val   "database.default.hostname" "$env_file")
    [ -z "$user" ]   && user=$(_env_val   "database.default.username" "$env_file")
    [ -z "$pass" ]   && pass=$(_env_val   "database.default.password" "$env_file")
    [ -z "$dbname" ] && dbname=$(_env_val "database.default.database" "$env_file")

    # Symfony: DATABASE_URL=mysql://user:pass@host:port/dbname
    if [ -z "$host" ]; then
        local db_url; db_url=$(_env_val DATABASE_URL "$env_file")
        if [[ "$db_url" =~ ^mysql://([^:]+):([^@]*)@([^:/]+)(:([0-9]+))?/([^?]+) ]]; then
            user="${BASH_REMATCH[1]}"; pass="${BASH_REMATCH[2]}"; host="${BASH_REMATCH[3]}"
            port="${BASH_REMATCH[5]}"; dbname="${BASH_REMATCH[6]}"
        fi
    fi

    if [ -z "$host" ] || [ -z "$user" ] || [ -z "$dbname" ]; then
        echo "  [DB] Could not parse DB credentials from .env — skipping connectivity check"
        return 2
    fi

    mysql -h "${host:-127.0.0.1}" -P "${port:-3306}" -u "$user" \
        ${pass:+-p"$pass"} --connect-timeout=5 -e "SELECT 1" "$dbname" &>/dev/null
}

cd "$APP_DIR"

echo "==> Pulling latest changes..."
git pull

# ─── Dependencies ────────────────────────────────────────────
if [ "$FRAMEWORK" != "none" ]; then
    echo "==> Installing Composer dependencies..."
    composer install --no-dev --optimize-autoloader --no-interaction
else
    : # No framework — uncomment if your project uses Composer:
    # composer install --no-dev --optimize-autoloader --no-interaction
fi

echo "==> Fixing ownership..."
sudo chown -R "$APP_USER:$APP_GROUP" "$APP_DIR"

# ─── Permissions ─────────────────────────────────────────────
if [ "$FRAMEWORK" = "laravel" ]; then
    echo "==> Fixing permissions..."
    perm "$APP_DIR/storage"
    perm "$APP_DIR/bootstrap/cache"
    # perm "$APP_DIR/public/uploads"   # uncomment if handling file uploads

elif [ "$FRAMEWORK" = "codeigniter" ]; then
    echo "==> Fixing permissions..."
    perm "$APP_DIR/writable"
    # perm "$APP_DIR/public/uploads"   # uncomment if handling file uploads

elif [ "$FRAMEWORK" = "symfony" ]; then
    echo "==> Fixing permissions..."
    perm "$APP_DIR/var/cache"
    perm "$APP_DIR/var/log"
    # perm "$APP_DIR/public/uploads"   # uncomment if handling file uploads

elif [ "$FRAMEWORK" = "cakephp" ]; then
    echo "==> Fixing permissions..."
    perm "$APP_DIR/logs"
    perm "$APP_DIR/tmp"
    # perm "$APP_DIR/webroot/uploads"  # uncomment if handling file uploads

else
    : # No framework — add project-specific perm lines here if needed
    # perm "$APP_DIR/uploads"
fi

# ─── Migrations ──────────────────────────────────────────────
if [ "$FRAMEWORK" != "none" ]; then
    echo "==> Checking database connectivity..."
    _db_status=0; db_reachable || _db_status=$?
    if [ "$_db_status" -eq 1 ]; then
        echo "  [SKIP] Database unreachable — migrations skipped"
    else
        [ "$_db_status" -eq 2 ] && echo "  [INFO] DB check skipped — attempting migrations anyway"
        echo "==> Running migrations..."
        if [ "$FRAMEWORK" = "laravel" ]; then
            php artisan migrate --force
        elif [ "$FRAMEWORK" = "codeigniter" ]; then
            php spark migrate --all
        elif [ "$FRAMEWORK" = "symfony" ]; then
            php bin/console doctrine:migrations:migrate --no-interaction
        elif [ "$FRAMEWORK" = "cakephp" ]; then
            bin/cake migrations migrate
        fi
    fi
fi

# ─── Cache ───────────────────────────────────────────────────
if [ "$FRAMEWORK" = "laravel" ]; then
    echo "==> Clearing caches..."
    php artisan config:clear
    php artisan view:clear
    php artisan cache:clear
    php artisan route:clear

elif [ "$FRAMEWORK" = "codeigniter" ]; then
    echo "==> Clearing caches..."
    php spark cache:clear

elif [ "$FRAMEWORK" = "symfony" ]; then
    echo "==> Clearing caches..."
    php bin/console cache:clear --env=prod --no-debug

elif [ "$FRAMEWORK" = "cakephp" ]; then
    echo "==> Clearing caches..."
    bin/cake orm_cache clear
    bin/cake cache clear_all

# else: no framework cache to clear
fi

echo "==> Done."
