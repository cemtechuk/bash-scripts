#!/bin/bash
# =============================================================================
# redeploy-template.sh — Regenerate deploy.sh for an existing vhost
# =============================================================================
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Paths ─────────────────────────────────────────────────────────────────────
SITES_AVAILABLE="/etc/apache2/sites-available"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/deploy.template.sh"

log()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()    { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }
die()    { err "$*"; exit 1; }

# Strip surrounding whitespace and quotes from a value
strip() { echo "$1" | sed "s/[[:space:]\"']//g"; }

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

# ── Template check ────────────────────────────────────────────────────────────
[[ -f "$TEMPLATE_FILE" ]] || die "deploy.template.sh not found at $TEMPLATE_FILE"

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║     Redeploy Template — RPi5 LAMP                ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"

# =============================================================================
# STEP 1 — Select VirtualHost
# =============================================================================
header "STEP 1 — Select VirtualHost"

mapfile -t CONFS < <(find "$SITES_AVAILABLE" -maxdepth 1 -name '*.conf' \
    ! -name '000-default.conf' ! -name 'default-ssl.conf' | sort)

[[ ${#CONFS[@]} -eq 0 ]] && die "No custom vhost configs found in $SITES_AVAILABLE."

echo ""
for i in "${!CONFS[@]}"; do
    printf "  %2d)  %s\n" $(( i + 1 )) "$(basename "${CONFS[$i]}")"
done
echo ""

read -rp "$(echo -e "${BOLD}Select a vhost [1-${#CONFS[@]}]:${RESET} ")" CHOICE
[[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#CONFS[@]} )) \
    || die "Invalid selection."

CONF_FILE="${CONFS[$(( CHOICE - 1 ))]}"
VHOST_NAME="$(basename "$CONF_FILE" .conf)"
log "Selected: $CONF_FILE"

# =============================================================================
# STEP 2 — Determine project root and detect existing settings
# =============================================================================
header "STEP 2 — Detecting Paths & Framework"

DOCROOT=$(grep -E '^\s*DocumentRoot\s+' "$CONF_FILE" | awk '{print $2}' | head -1)
[[ -n "$DOCROOT" ]] || die "Could not parse DocumentRoot from $CONF_FILE."

# If DocumentRoot ends in a framework public subdir, strip it to get project root
LAST_PART=$(basename "$DOCROOT")
if [[ "$LAST_PART" == "public" || "$LAST_PART" == "webroot" ]]; then
    BASE_DOCROOT=$(dirname "$DOCROOT")
else
    BASE_DOCROOT="$DOCROOT"
fi

log "DocumentRoot : $DOCROOT"
log "Project root : $BASE_DOCROOT"

# Read current values from existing deploy.sh (if present)
EXISTING_DEPLOY="${BASE_DOCROOT}/deploy.sh"
FRAMEWORK="none"
DEPLOY_USER="${SUDO_USER:-cem}"

if [[ -f "$EXISTING_DEPLOY" ]]; then
    DETECTED_FW=$(grep -E '^FRAMEWORK=' "$EXISTING_DEPLOY" 2>/dev/null \
        | head -1 | cut -d'=' -f2-) || true
    DETECTED_USER=$(grep -E '^APP_USER=' "$EXISTING_DEPLOY" 2>/dev/null \
        | head -1 | cut -d'=' -f2-) || true
    [[ -n "$DETECTED_FW"   ]] && FRAMEWORK="$(strip "$DETECTED_FW")"
    [[ -n "$DETECTED_USER" ]] && DEPLOY_USER="$(strip "$DETECTED_USER")"
    log "Detected from existing deploy.sh — framework: ${FRAMEWORK}, user: ${DEPLOY_USER}"
else
    warn "No existing deploy.sh at $EXISTING_DEPLOY — will create fresh."
fi

# =============================================================================
# STEP 3 — Confirm / override framework
# =============================================================================
header "STEP 3 — Framework"

echo ""
echo -e "  ${BOLD}Select framework:${RESET}"
echo "    1) Laravel"
echo "    2) CodeIgniter 4"
echo "    3) Symfony"
echo "    4) CakePHP"
echo "    5) None (plain PHP / static)"
echo ""

case "$FRAMEWORK" in
    laravel)     CURRENT_NUM=1 ;;
    codeigniter) CURRENT_NUM=2 ;;
    symfony)     CURRENT_NUM=3 ;;
    cakephp)     CURRENT_NUM=4 ;;
    *)           CURRENT_NUM=5 ;;
esac

read -rp "$(echo -e "${BOLD}Framework${RESET} [1-5, current ${CURRENT_NUM}]: ")" FW_INPUT
case "${FW_INPUT:-$CURRENT_NUM}" in
    1) FRAMEWORK="laravel" ;;
    2) FRAMEWORK="codeigniter" ;;
    3) FRAMEWORK="symfony" ;;
    4) FRAMEWORK="cakephp" ;;
    *) FRAMEWORK="none" ;;
esac
log "Framework: $FRAMEWORK"

# =============================================================================
# STEP 4 — Confirm app user and project root
# =============================================================================
header "STEP 4 — Confirm Details"

read -rp "$(echo -e "${BOLD}App user${RESET} [${DEPLOY_USER}]: ")" USER_INPUT
DEPLOY_USER="${USER_INPUT:-$DEPLOY_USER}"

read -rp "$(echo -e "${BOLD}Project root${RESET} [${BASE_DOCROOT}]: ")" DIR_INPUT
BASE_DOCROOT="${DIR_INPUT:-$BASE_DOCROOT}"
BASE_DOCROOT="${BASE_DOCROOT%/}"

[[ -d "$BASE_DOCROOT" ]] || die "Directory does not exist: $BASE_DOCROOT"

DEPLOY_SCRIPT="${BASE_DOCROOT}/deploy.sh"

# =============================================================================
# STEP 5 — Write deploy.sh
# =============================================================================
header "STEP 5 — Writing deploy.sh"

# Back up existing deploy.sh before overwriting
if [[ -f "$DEPLOY_SCRIPT" ]]; then
    BACKUP="${DEPLOY_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$DEPLOY_SCRIPT" "$BACKUP"
    ok "Backed up existing deploy.sh → $(basename "$BACKUP")"
fi

cp "$TEMPLATE_FILE" "$DEPLOY_SCRIPT"
sed -i "s|APP_DIR=\"/var/www/HOSTNAME\"|APP_DIR=\"${BASE_DOCROOT}\"|" "$DEPLOY_SCRIPT"
sed -i "s|FRAMEWORK=\"none\"|FRAMEWORK=\"${FRAMEWORK}\"|"             "$DEPLOY_SCRIPT"
sed -i "s|APP_USER=\"cem\"|APP_USER=\"${DEPLOY_USER}\"|"              "$DEPLOY_SCRIPT"
chmod 750 "$DEPLOY_SCRIPT"
chown "${DEPLOY_USER}:www-data" "$DEPLOY_SCRIPT"

ok "deploy.sh written to $DEPLOY_SCRIPT"

# =============================================================================
# REPORT
# =============================================================================
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║                    DONE                          ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  ${BOLD}VHost      :${RESET} $VHOST_NAME"
echo -e "  ${BOLD}Project    :${RESET} $BASE_DOCROOT"
echo -e "  ${BOLD}Framework  :${RESET} $FRAMEWORK"
echo -e "  ${BOLD}App user   :${RESET} $DEPLOY_USER"
echo -e "  ${BOLD}Deploy     :${RESET} $DEPLOY_SCRIPT"
echo ""
