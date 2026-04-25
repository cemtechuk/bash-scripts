#!/bin/bash
set -e

# ─────────────────────────────────────────────────────────────
# CONFIGURATION — edit these before deploying
# ─────────────────────────────────────────────────────────────
APP_DIR="/var/www/HOSTNAME"
APP_USER="cem"
APP_GROUP="www-data"

# Framework: laravel | codeigniter | none
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

# else: no framework cache to clear
fi

echo "==> Done."
