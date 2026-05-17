#!/bin/bash
# =============================================================================
# remove-subdomain-nginx.sh — Nginx Subdomain Remover for Raspberry Pi 5
# =============================================================================
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Paths ─────────────────────────────────────────────────────────────────────
SITES_AVAILABLE="/etc/nginx/sites-available"
SITES_ENABLED="/etc/nginx/sites-enabled"
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
CONF_FILE_BACKUP=""
CF_CONFIG_BACKUP=""
CF_CONFIG=""
SYMLINK_REMOVED=false
CONF_FILE=""
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

    # Restore vhost conf before re-linking
    if [[ -n "$CONF_FILE_BACKUP" && -f "$CONF_FILE_BACKUP" ]]; then
        cp "$CONF_FILE_BACKUP" "$CONF_FILE"
        rm -f "$CONF_FILE_BACKUP"
        echo -e "${YELLOW}[ROLLBACK]${RESET} Restored $CONF_FILE from backup"
    fi

    # Restore symlink if we removed it
    if [[ "$SYMLINK_REMOVED" == "true" && -n "$CONF_FILE" ]]; then
        SYMLINK="${SITES_ENABLED}/$(basename "$CONF_FILE")"
        if [[ ! -L "$SYMLINK" && -f "$CONF_FILE" ]]; then
            ln -s "$CONF_FILE" "$SYMLINK"
            echo -e "${YELLOW}[ROLLBACK]${RESET} Restored symlink $SYMLINK"
        fi
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
    echo -e "  ${BOLD}Server conf:${RESET} ${CONF_FILE:-n/a}"
    [[ -n "$CF_CONFIG" ]] && echo -e "  ${BOLD}CF config  :${RESET} $CF_CONFIG"
    echo ""
    echo -e "  ${BOLD}Actions performed:${RESET}"
    for entry in "${REPORT[@]}"; do
        echo "    $entry"
    done
    echo ""
    echo -e "${GREEN}  Done! ${BOLD}${SUBDOMAIN:-n/a}${RESET}${GREEN} has been removed from nginx.${RESET}"
    echo -e "${YELLOW}  Document root ${DOCROOT:-n/a} was left intact.${RESET}"
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

# =============================================================================
# STEP 1 — Select domain to remove
# =============================================================================
header "STEP 1 — Select Domain to Remove"

mapfile -t CONF_FILES < <(find "$SITES_AVAILABLE" -maxdepth 1 -name "*.conf" \
    ! -name "default" ! -name "default.conf" | sort)

if [[ ${#CONF_FILES[@]} -eq 0 ]]; then
    die "No custom site configs found in $SITES_AVAILABLE"
fi

echo ""
echo -e "  ${BOLD}Available sites:${RESET}"
for i in "${!CONF_FILES[@]}"; do
    ENABLED_MARK=""
    SYMLINK_CHECK="${SITES_ENABLED}/$(basename "${CONF_FILES[$i]}")"
    [[ -L "$SYMLINK_CHECK" ]] && ENABLED_MARK=" ${GREEN}[enabled]${RESET}"
    printf "    [%d] %s%b\n" "$((i+1))" "$(basename "${CONF_FILES[$i]}" .conf)" "$ENABLED_MARK"
done
echo ""

while true; do
    read -rp "$(echo -e "  ${BOLD}Enter number:${RESET} ")" SELECTION
    if [[ "$SELECTION" =~ ^[0-9]+$ ]] && (( SELECTION >= 1 && SELECTION <= ${#CONF_FILES[@]} )); then
        CONF_FILE="${CONF_FILES[$((SELECTION-1))]}"
        SUBDOMAIN="$(basename "$CONF_FILE" .conf)"
        break
    fi
    echo -e "  ${YELLOW}Invalid selection — enter a number from the list.${RESET}"
done

log "Selected: $SUBDOMAIN ($CONF_FILE)"

# =============================================================================
# STEP 2 — Parse config and verify all targets exist
# =============================================================================
header "STEP 2 — Reading & Verifying Configuration"

# Extract port from listen directive (handles: listen PORT; listen IP:PORT; listen PORT default_server;)
PORT=$(grep -E '^\s*listen\s+' "$CONF_FILE" | grep -v 'ssl' | head -1 \
    | grep -oE '\b[0-9]{1,5}\b' | tail -1 || true)
if [[ -z "$PORT" ]]; then
    warn "Cannot determine port from $CONF_FILE — will display n/a in report."
fi
[[ -n "$PORT" ]] && log "Port found in server block: $PORT"

# Extract root directive for display
DOCROOT=$(grep -E '^\s*root\s+' "$CONF_FILE" | awk '{print $2}' | head -1 | tr -d ';' || true)
[[ -z "$DOCROOT" ]] && warn "root directive not found in $CONF_FILE — cannot display in report"

# Check for symlink in sites-enabled
SYMLINK="${SITES_ENABLED}/$(basename "$CONF_FILE")"
SYMLINK_FOUND=false
if [[ -L "$SYMLINK" ]]; then
    SYMLINK_FOUND=true
    log "Found enabled symlink: $SYMLINK"
else
    warn "No symlink found at $SYMLINK — site may already be disabled"
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
if [[ "$SYMLINK_FOUND" == "true" ]]; then
    printf "    ${RED}✖${RESET}  Enabled symlink    →  %s\n" "$SYMLINK"
else
    printf "    ${YELLOW}⚠${RESET}  Enabled symlink    →  not found (already removed — skipping)\n"
fi
printf "    ${RED}✖${RESET}  Server block config →  %s\n" "$CONF_FILE"
if [[ "$CF_INGRESS_FOUND" == "true" ]]; then
    printf "    ${RED}✖${RESET}  CF ingress rule    →  hostname: %s  from %s\n" "$SUBDOMAIN" "$CF_CONFIG"
fi
echo ""
echo -e "  ${BOLD}${GREEN}The following will NOT be removed:${RESET}"
printf "    ${GREEN}✔${RESET}  Document root  →  %s\n" "${DOCROOT:-unknown (not found in config)}"
echo ""

# =============================================================================
# STEP 4 — Confirm
# =============================================================================
header "STEP 4 — Confirm Removal"
echo ""
echo -e "  ${BOLD}${RED}This will permanently remove nginx config for: ${SUBDOMAIN}${RESET}"
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

# — Backup vhost conf —
CONF_FILE_BACKUP="${CONF_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
cp "$CONF_FILE" "$CONF_FILE_BACKUP"
log "Backed up $CONF_FILE → $CONF_FILE_BACKUP"

# — Remove symlink from sites-enabled —
if [[ "$SYMLINK_FOUND" == "true" ]]; then
    rm -f "$SYMLINK"
    SYMLINK_REMOVED=true
    ok "Removed enabled symlink $SYMLINK"
else
    warn "Skipped symlink removal — not found in $SITES_ENABLED"
fi

# — Delete server block conf —
rm -f "$CONF_FILE"
ok "Removed $CONF_FILE"

# — Remove CF ingress entry —
CF_NEEDS_RESTART=false
if [[ "$CF_INGRESS_FOUND" == "true" ]]; then
    CF_CONFIG_BACKUP="${CF_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$CF_CONFIG" "$CF_CONFIG_BACKUP"
    log "Backed up $CF_CONFIG → $CF_CONFIG_BACKUP"

    INGRESS_LINE_NUM=$(grep -nE "^\s*-\s+hostname:\s+${SUBDOMAIN}\s*$" "$CF_CONFIG" | head -1 | cut -d: -f1 || true)
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
[[ -f "$CONF_FILE_BACKUP" ]] && rm -f "$CONF_FILE_BACKUP"
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
