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

cd "$APP_DIR"

echo "==> Pulling latest changes..."
git pull

echo "==> Fixing ownership..."
sudo chown -R "$APP_USER:$APP_GROUP" "$APP_DIR"

# ─── Permissions ─────────────────────────────────────────────
if [ "$FRAMEWORK" = "laravel" ]; then
    echo "==> Fixing permissions..."
    sudo chmod -R 775 "$APP_DIR/storage"
    sudo chmod -R 775 "$APP_DIR/bootstrap/cache"
    # sudo chmod -R 775 "$APP_DIR/public/uploads"   # uncomment if handling file uploads

elif [ "$FRAMEWORK" = "codeigniter" ]; then
    echo "==> Fixing permissions..."
    sudo chmod -R 775 "$APP_DIR/writable"
    # sudo chmod -R 775 "$APP_DIR/public/uploads"   # uncomment if handling file uploads

elif [ "$FRAMEWORK" = "symfony" ]; then
    echo "==> Fixing permissions..."
    sudo chmod -R 775 "$APP_DIR/var/cache"
    sudo chmod -R 775 "$APP_DIR/var/log"
    # sudo chmod -R 775 "$APP_DIR/public/uploads"   # uncomment if handling file uploads

elif [ "$FRAMEWORK" = "cakephp" ]; then
    echo "==> Fixing permissions..."
    sudo chmod -R 775 "$APP_DIR/logs"
    sudo chmod -R 775 "$APP_DIR/tmp"
    # sudo chmod -R 775 "$APP_DIR/webroot/uploads"  # uncomment if handling file uploads

else
    : # No framework — add project-specific chmod lines here if needed
    # sudo chmod -R 775 "$APP_DIR/uploads"
fi

# ─── Migrations ──────────────────────────────────────────────
if [ "$FRAMEWORK" = "laravel" ]; then
    echo "==> Running migrations..."
    php artisan migrate --force

elif [ "$FRAMEWORK" = "codeigniter" ]; then
    echo "==> Running migrations..."
    php spark migrate --all

elif [ "$FRAMEWORK" = "symfony" ]; then
    echo "==> Running migrations..."
    php bin/console doctrine:migrations:migrate --no-interaction

elif [ "$FRAMEWORK" = "cakephp" ]; then
    echo "==> Running migrations..."
    bin/cake migrations migrate

# else: no migrations
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
