#!/bin/bash
# =============================================================================
# remove-subdomain-nginx.sh — Nginx Subdomain Remover for Raspberry Pi 5
# =============================================================================
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Paths ─────────────────────────────────────────────────────────────────────
SITES_CONF="/etc/nginx/conf.d/sites.conf"
CF_CONFIG_CANDIDATES=(
    "/etc/cloudflared/config.yml"
    "/etc/cloudflared/config.yaml"
    "/root/.cloudflared/config.yml"
    "/root/.cloudflared/config.yaml"
    "$HOME/.cloudflared/config.yml"
    "$HOME/.cloudflared/config.yaml"
)
REPORT=()

# ── Rollback tracking ─────────────────────────────────────────────────────────
SITES_CONF_BACKUP=""
CF_CONFIG_BACKUP=""
CF_CONFIG=""
INCLUDE_REMOVED=false
NGINX_CONF=""
SUBDOMAIN=""
PORT=""
DOCROOT=""

log()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET}    $*"; REPORT+=("✔ $*"); }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; REPORT+=("⚠ $*"); }
err()    { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }

# ── Rollback ──────────────────────────────────────────────────────────────────
rollback() {
    echo -e "\n${RED}${BOLD}!! FAILURE DETECTED — Rolling back changes...${RESET}"

    # Restore sites.conf (this restores the include line if we removed it)
    if [[ -n "$SITES_CONF_BACKUP" && -f "$SITES_CONF_BACKUP" ]]; then
        cp "$SITES_CONF_BACKUP" "$SITES_CONF"
        rm -f "$SITES_CONF_BACKUP"
        echo -e "${YELLOW}[ROLLBACK]${RESET} Restored $SITES_CONF from backup"
    fi

    # Restore CF config
    if [[ -n "$CF_CONFIG_BACKUP" && -f "$CF_CONFIG_BACKUP" && -n "$CF_CONFIG" ]]; then
        cp "$CF_CONFIG_BACKUP" "$CF_CONFIG"
        rm -f "$CF_CONFIG_BACKUP"
        echo -e "${YELLOW}[ROLLBACK]${RESET} Restored $CF_CONFIG from backup"
    fi

    nginx -t &>/dev/null && systemctl reload nginx &>/dev/null || true

    echo -e "${RED}Rollback complete. No permanent changes were made.${RESET}\n"
}

trap 'EXIT_CODE=$?; if [[ $EXIT_CODE -ne 0 ]]; then rollback; fi' EXIT
trap 'echo -e "\n${YELLOW}Interrupted by user.${RESET}"; exit 130' INT TERM

die() {
    err "$*"
    exit 1
}

print_report() {
    echo ""
    echo -e "${BOLD}${GREEN}"
    echo "  ╔══════════════════════════════════════════════════╗"
    echo "  ║                  FINAL REPORT                    ║"
    echo "  ╚══════════════════════════════════════════════════╝"
    echo -e "${RESET}"
    echo -e "  ${BOLD}Date/Time  :${RESET} $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "  ${BOLD}Hostname   :${RESET} ${SUBDOMAIN:-n/a}"
    echo -e "  ${BOLD}Port       :${RESET} ${PORT:-n/a}"
    echo -e "  ${BOLD}DocRoot    :${RESET} ${DOCROOT:-n/a}  ${YELLOW}(not deleted)${RESET}"
    echo -e "  ${BOLD}nginx conf :${RESET} ${NGINX_CONF:-n/a}  ${YELLOW}(not deleted)${RESET}"
    echo -e "  ${BOLD}sites.conf :${RESET} $SITES_CONF"
    [[ -n "$CF_CONFIG" ]] && echo -e "  ${BOLD}CF config  :${RESET} $CF_CONFIG"
    echo ""
    echo -e "  ${BOLD}Actions performed:${RESET}"
    for entry in "${REPORT[@]}"; do
        echo "    $entry"
    done
    echo ""
    echo -e "${GREEN}  Done! ${BOLD}${SUBDOMAIN:-n/a}${RESET}${GREEN} has been removed from nginx.${RESET}"
    echo -e "${YELLOW}  Project files and nginx.conf were left intact.${RESET}"
    echo ""
}

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${RED}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║       Nginx Subdomain Remover — RPi5             ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"

# ── Sanity check ──────────────────────────────────────────────────────────────
[[ -f "$SITES_CONF" ]] || die "Main sites config not found: $SITES_CONF"

# =============================================================================
# STEP 1 — Select domain to remove
# =============================================================================
header "STEP 1 — Select Domain to Remove"

# Build list from include directives in sites.conf
mapfile -t INCLUDES < <(grep -E '^\s*include\s+' "$SITES_CONF" \
    | awk '{print $2}' | tr -d ';' | grep -v '^$')

if [[ ${#INCLUDES[@]} -eq 0 ]]; then
    die "No include directives found in $SITES_CONF"
fi

echo ""
echo -e "  ${BOLD}Available sites:${RESET}"
for i in "${!INCLUDES[@]}"; do
    INC_PATH="${INCLUDES[$i]}"
    SITE_LABEL=$(basename "$(dirname "$INC_PATH")")
    MISSING_MARK=""
    [[ ! -f "$INC_PATH" ]] && MISSING_MARK=" ${YELLOW}[conf file missing]${RESET}"
    printf "    [%d] %s%b  ${CYAN}(%s)${RESET}\n" "$((i+1))" "$SITE_LABEL" "$MISSING_MARK" "$INC_PATH"
done
echo ""

while true; do
    read -rp "$(echo -e "  ${BOLD}Enter number:${RESET} ")" SELECTION
    if [[ "$SELECTION" =~ ^[0-9]+$ ]] && (( SELECTION >= 1 && SELECTION <= ${#INCLUDES[@]} )); then
        NGINX_CONF="${INCLUDES[$((SELECTION-1))]}"
        SUBDOMAIN=$(basename "$(dirname "$NGINX_CONF")")
        break
    fi
    echo -e "  ${YELLOW}Invalid selection — enter a number from the list.${RESET}"
done

log "Selected: $SUBDOMAIN ($NGINX_CONF)"

# =============================================================================
# STEP 2 — Parse config and verify
# =============================================================================
header "STEP 2 — Reading & Verifying Configuration"

if [[ ! -f "$NGINX_CONF" ]]; then
    warn "nginx.conf not found at $NGINX_CONF — will only remove the include line."
    PORT="n/a"
    DOCROOT="n/a"
else
    # Extract port (skip ssl lines; take last number on the first plain listen line)
    PORT=$(grep -E '^\s*listen\s+' "$NGINX_CONF" | grep -v 'ssl' | head -1 \
        | grep -oE '\b[0-9]{1,5}\b' | tail -1 || true)
    [[ -z "$PORT" ]] && { warn "Cannot determine port from $NGINX_CONF."; PORT="n/a"; }
    [[ "$PORT" != "n/a" ]] && log "Port: $PORT"

    # Extract root directive
    DOCROOT=$(grep -E '^\s*root\s+' "$NGINX_CONF" | awk '{print $2}' | head -1 | tr -d ';' || true)
    [[ -z "$DOCROOT" ]] && { warn "root directive not found in $NGINX_CONF."; DOCROOT="n/a"; }
    [[ "$DOCROOT" != "n/a" ]] && log "Document root: $DOCROOT"
fi

# Check for a Cloudflare ingress entry
CF_INGRESS_FOUND=false
for candidate in "${CF_CONFIG_CANDIDATES[@]}"; do
    if [[ -f "$candidate" ]]; then
        CF_CONFIG="$candidate"
        break
    fi
done

if [[ -n "$CF_CONFIG" ]]; then
    if grep -qE "^\s*-\s+hostname:\s+${SUBDOMAIN}\s*$" "$CF_CONFIG" 2>/dev/null; then
        CF_INGRESS_FOUND=true
        log "Found Cloudflare ingress for $SUBDOMAIN in $CF_CONFIG"
    else
        log "No Cloudflare ingress entry for $SUBDOMAIN — will skip"
    fi
fi

# =============================================================================
# STEP 3 — Preview
# =============================================================================
header "STEP 3 — Preview of Changes"
echo ""
echo -e "  ${BOLD}${RED}The following will be removed:${RESET}"
echo ""
printf "    ${RED}✖${RESET}  Include directive  →  'include %s;'  from %s\n" "$NGINX_CONF" "$SITES_CONF"
if [[ "$CF_INGRESS_FOUND" == "true" ]]; then
    printf "    ${RED}✖${RESET}  CF ingress rule    →  hostname: %s  from %s\n" "$SUBDOMAIN" "$CF_CONFIG"
fi
echo ""
echo -e "  ${BOLD}${GREEN}The following will NOT be removed:${RESET}"
printf "    ${GREEN}✔${RESET}  nginx.conf   →  %s\n" "$NGINX_CONF"
printf "    ${GREEN}✔${RESET}  Document root →  %s\n" "${DOCROOT:-unknown}"
echo ""

# =============================================================================
# STEP 4 — Confirm
# =============================================================================
header "STEP 4 — Confirm Removal"
echo ""
echo -e "  ${BOLD}${RED}This will deregister nginx config for: ${SUBDOMAIN}${RESET}"
echo ""
read -rp "$(echo -e "  ${BOLD}Type 'yes' to proceed, anything else to abort:${RESET} ")" CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo -e "\n${YELLOW}Aborted. No changes were made.${RESET}\n"
    trap - EXIT
    exit 0
fi

# =============================================================================
# STEP 5 — Execute
# =============================================================================
header "STEP 5 — Removing Configuration"

# — Backup sites.conf —
SITES_CONF_BACKUP="${SITES_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
cp "$SITES_CONF" "$SITES_CONF_BACKUP"
log "Backed up $SITES_CONF → $SITES_CONF_BACKUP"

# — Remove include line from sites.conf —
ESCAPED=$(echo "$NGINX_CONF" | sed 's|/|\\/|g')
INCLUDE_LINE_NUM=$(grep -n "include ${ESCAPED};" "$SITES_CONF" | head -1 | cut -d: -f1 || true)
if [[ -z "$INCLUDE_LINE_NUM" ]]; then
    die "Include directive for $NGINX_CONF not found in $SITES_CONF — cannot remove it"
fi
sed -i "${INCLUDE_LINE_NUM}d" "$SITES_CONF"
INCLUDE_REMOVED=true
ok "Removed 'include ${NGINX_CONF};' from $SITES_CONF"

# — Remove CF ingress entry —
CF_NEEDS_RESTART=false
if [[ "$CF_INGRESS_FOUND" == "true" ]]; then
    CF_CONFIG_BACKUP="${CF_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$CF_CONFIG" "$CF_CONFIG_BACKUP"
    log "Backed up $CF_CONFIG → $CF_CONFIG_BACKUP"

    INGRESS_LINE_NUM=$(grep -nE "^\s*-\s+hostname:\s+${SUBDOMAIN}\s*$" "$CF_CONFIG" \
        | head -1 | cut -d: -f1 || true)
    if [[ -z "$INGRESS_LINE_NUM" ]]; then
        die "Cloudflare ingress entry for $SUBDOMAIN not found in $CF_CONFIG — cannot remove it"
    fi

    NEXT_LINE=$((INGRESS_LINE_NUM + 1))
    if sed -n "${NEXT_LINE}p" "$CF_CONFIG" | grep -qE "^\s+service:"; then
        sed -i "${INGRESS_LINE_NUM},${NEXT_LINE}d" "$CF_CONFIG"
    else
        sed -i "${INGRESS_LINE_NUM}d" "$CF_CONFIG"
    fi

    if grep -qE "hostname:\s+${SUBDOMAIN}" "$CF_CONFIG"; then
        die "Cloudflare ingress for $SUBDOMAIN still present in $CF_CONFIG after deletion attempt"
    fi
    ok "Removed Cloudflare ingress for $SUBDOMAIN from $CF_CONFIG"
    CF_NEEDS_RESTART=true
fi

# — nginx configtest & reload —
log "Testing nginx configuration..."
if ! nginx -t 2>&1; then
    die "nginx config test failed after removal"
fi
ok "nginx config test passed"

log "Reloading nginx..."
if ! systemctl reload nginx; then
    die "nginx failed to reload"
fi
ok "nginx reloaded"

# All succeeded — disarm trap and clean up backups
trap - EXIT
rm -f "$SITES_CONF_BACKUP"
[[ -n "$CF_CONFIG_BACKUP" && -f "$CF_CONFIG_BACKUP" ]] && rm -f "$CF_CONFIG_BACKUP"

# =============================================================================
# FINAL REPORT
# =============================================================================
print_report

# Restart cloudflared after report — avoids dropping tunnel before user reads output
if [[ "$CF_NEEDS_RESTART" == "true" ]]; then
    warn "Restarting cloudflared now — if connected via the tunnel, your connection will drop momentarily."
    if systemctl restart cloudflared 2>/dev/null; then
        echo -e "${GREEN}[OK]${RESET}    cloudflared restarted successfully"
    else
        echo -e "${YELLOW}[WARN]${RESET}  Could not restart cloudflared (check 'systemctl status cloudflared')."
    fi
fi
