#!/usr/bin/env bash
# create_mariadb.sh — Creates a MariaDB database, user, and grants local-network access.
# Rolls back all changes if any step fails.

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
DB_NAME="${1:-}"
DB_USER="${2:-}"
DB_PASS="${3:-}"
# Subnet allowed to connect remotely (e.g. 192.168.1.%) — '%' means any host on that subnet
ALLOWED_HOST="${4:-192.168.1.%}"

# ─── Root credentials (adjust or use --defaults-file if you prefer) ───────────
MYSQL_ROOT_USER="root"
# Leave empty to be prompted, or set MYSQL_ROOT_PASSWORD env var beforehand
MYSQL_ROOT_PASS="${MYSQL_ROOT_PASSWORD:-}"

# ─── Helpers ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    echo "Usage: $0 <db_name> <db_user> <db_password> [allowed_host]"
    echo ""
    echo "  db_name       Name of the database to create"
    echo "  db_user       MariaDB user to create"
    echo "  db_password   Password for the new user"
    echo "  allowed_host  IP/subnet allowed to connect remotely (default: 192.168.1.%)"
    echo ""
    echo "  Export MYSQL_ROOT_PASSWORD to avoid the root password prompt."
    echo ""
    echo "Examples:"
    echo "  $0 myapp myapp_user 'S3cr3t!'"
    echo "  $0 myapp myapp_user 'S3cr3t!' '10.0.0.%'"
    exit 1
}

# ─── Rollback state ───────────────────────────────────────────────────────────
DB_CREATED=false
USER_LOCALHOST_CREATED=false
USER_NETWORK_CREATED=false

rollback() {
    error "Something went wrong — rolling back..."

    local mc
    mc=$(mysql_cmd)

    if $USER_NETWORK_CREATED; then
        warn "Dropping user '${DB_USER}'@'${ALLOWED_HOST}'..."
        $mc -e "DROP USER IF EXISTS '${DB_USER}'@'${ALLOWED_HOST}';" 2>/dev/null || true
    fi

    if $USER_LOCALHOST_CREATED; then
        warn "Dropping user '${DB_USER}'@'localhost'..."
        $mc -e "DROP USER IF EXISTS '${DB_USER}'@'localhost';" 2>/dev/null || true
    fi

    if $DB_CREATED; then
        warn "Dropping database '${DB_NAME}'..."
        $mc -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;" 2>/dev/null || true
    fi

    $mc -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    error "Rollback complete. No changes were left behind."
}

trap rollback ERR

# ─── Build mysql command ───────────────────────────────────────────────────────
mysql_cmd() {
    if [[ -n "$MYSQL_ROOT_PASS" ]]; then
        echo "mysql -u${MYSQL_ROOT_USER} -p${MYSQL_ROOT_PASS} --batch --silent"
    else
        echo "mysql -u${MYSQL_ROOT_USER} -p --batch --silent"
    fi
}

# ─── Validate input ───────────────────────────────────────────────────────────
[[ -z "$DB_NAME"  ]] && { error "Missing db_name.";     usage; }
[[ -z "$DB_USER"  ]] && { error "Missing db_user.";     usage; }
[[ -z "$DB_PASS"  ]] && { error "Missing db_password."; usage; }

# Sanity-check names (letters, digits, underscores only)
if [[ ! "$DB_NAME" =~ ^[a-zA-Z0-9_]+$ ]]; then
    error "db_name '${DB_NAME}' contains invalid characters (allowed: a-z A-Z 0-9 _)."
    exit 1
fi
if [[ ! "$DB_USER" =~ ^[a-zA-Z0-9_]+$ ]]; then
    error "db_user '${DB_USER}' contains invalid characters (allowed: a-z A-Z 0-9 _)."
    exit 1
fi

# ─── Prompt for root password if not set ──────────────────────────────────────
if [[ -z "$MYSQL_ROOT_PASS" ]]; then
    read -rsp "Enter MariaDB root password: " MYSQL_ROOT_PASS
    echo
fi

MC=$(mysql_cmd)

# ─── Verify root connection ───────────────────────────────────────────────────
info "Testing root connection to MariaDB..."
if ! $MC -e "SELECT 1;" > /dev/null 2>&1; then
    error "Cannot connect to MariaDB as root. Check the password and that MariaDB is running."
    exit 1
fi
info "Connected successfully."

# ─── Check for conflicts ──────────────────────────────────────────────────────
info "Checking for existing database/user conflicts..."

existing_db=$($MC -e "SHOW DATABASES LIKE '${DB_NAME}';" 2>/dev/null || true)
if [[ -n "$existing_db" ]]; then
    error "Database '${DB_NAME}' already exists. Choose a different name or drop it first."
    exit 1
fi

existing_user=$($MC -e "SELECT User FROM mysql.user WHERE User='${DB_USER}' AND (Host='localhost' OR Host='${ALLOWED_HOST}');" 2>/dev/null || true)
if [[ -n "$existing_user" ]]; then
    error "User '${DB_USER}' already exists on 'localhost' or '${ALLOWED_HOST}'. Choose a different username."
    exit 1
fi

# ─── Create database ──────────────────────────────────────────────────────────
info "Creating database '${DB_NAME}'..."
$MC -e "CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
DB_CREATED=true

# ─── Create user (localhost) ──────────────────────────────────────────────────
info "Creating user '${DB_USER}'@'localhost'..."
$MC -e "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
USER_LOCALHOST_CREATED=true

# ─── Create user (network) ───────────────────────────────────────────────────
info "Creating user '${DB_USER}'@'${ALLOWED_HOST}' for remote LAN access..."
$MC -e "CREATE USER '${DB_USER}'@'${ALLOWED_HOST}' IDENTIFIED BY '${DB_PASS}';"
USER_NETWORK_CREATED=true

# ─── Grant permissions ────────────────────────────────────────────────────────
info "Granting ALL privileges on '${DB_NAME}' to both user entries..."
$MC -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
$MC -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${ALLOWED_HOST}';"
$MC -e "FLUSH PRIVILEGES;"

# ─── Verify MariaDB is listening on all interfaces ────────────────────────────
BIND_ADDR=$(grep -rE '^\s*bind-address\s*=' /etc/mysql/ 2>/dev/null | awk -F= '{print $2}' | tr -d ' ' | head -1)
if [[ "$BIND_ADDR" == "127.0.0.1" ]]; then
    warn "MariaDB bind-address is set to 127.0.0.1 in /etc/mysql/."
    warn "Remote connections will be blocked until you change it:"
    warn "  1. Edit /etc/mysql/mariadb.conf.d/50-server.cnf (or my.cnf)"
    warn "     Change:  bind-address = 127.0.0.1"
    warn "     To:      bind-address = 0.0.0.0"
    warn "  2. Then run: sudo systemctl restart mariadb"
fi

# ─── Check firewall ───────────────────────────────────────────────────────────
if command -v ufw &>/dev/null; then
    UFW_STATUS=$(ufw status 2>/dev/null | head -1 || true)
    if [[ "$UFW_STATUS" == *"active"* ]]; then
        RULE_EXISTS=$(ufw status | grep -E "3306" || true)
        if [[ -z "$RULE_EXISTS" ]]; then
            warn "UFW firewall is active but has no rule for port 3306."
            warn "Run this to allow LAN access (adjust subnet as needed):"
            warn "  sudo ufw allow from ${ALLOWED_HOST%\%}0/24 to any port 3306"
        else
            info "UFW already has a rule covering port 3306."
        fi
    fi
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN} Setup complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "  Database : ${DB_NAME}"
echo "  User     : ${DB_USER}"
echo "  Hosts    : localhost, ${ALLOWED_HOST}"
echo ""
echo "  Connection string (from LAN):"
echo "  mysql -h <raspberry-pi-ip> -u ${DB_USER} -p ${DB_NAME}"
echo ""
