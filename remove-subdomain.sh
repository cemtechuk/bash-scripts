#!/bin/bash
# =============================================================================
# remove-subdomain.sh — Apache Subdomain Remover for Raspberry Pi 5 LAMP Server
# =============================================================================
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Paths ─────────────────────────────────────────────────────────────────────
PORTS_CONF="/etc/apache2/ports.conf"
SITES_AVAILABLE="/etc/apache2/sites-available"
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
PORTS_CONF_BACKUP=""
CONF_FILE_BACKUP=""
CF_CONFIG_BACKUP=""
CF_CONFIG=""
A2DISSITE_DONE=false
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

    # Restore ports.conf first
    if [[ -n "$PORTS_CONF_BACKUP" && -f "$PORTS_CONF_BACKUP" ]]; then
        cp "$PORTS_CONF_BACKUP" "$PORTS_CONF"
        rm -f "$PORTS_CONF_BACKUP"
        echo -e "${YELLOW}[ROLLBACK]${RESET} Restored $PORTS_CONF from backup"
    fi

    # Restore vhost conf before re-enabling (a2ensite needs the file present)
    if [[ -n "$CONF_FILE_BACKUP" && -f "$CONF_FILE_BACKUP" ]]; then
        cp "$CONF_FILE_BACKUP" "$CONF_FILE"
        rm -f "$CONF_FILE_BACKUP"
        echo -e "${YELLOW}[ROLLBACK]${RESET} Restored $CONF_FILE from backup"
    fi

    # Re-enable site if we disabled it
    if [[ "$A2DISSITE_DONE" == "true" && -n "$SUBDOMAIN" ]]; then
        a2ensite "${SUBDOMAIN}.conf" &>/dev/null || true
        echo -e "${YELLOW}[ROLLBACK]${RESET} Re-enabled site: $SUBDOMAIN"
    fi

    # Restore CF config
    if [[ -n "$CF_CONFIG_BACKUP" && -f "$CF_CONFIG_BACKUP" && -n "$CF_CONFIG" ]]; then
        cp "$CF_CONFIG_BACKUP" "$CF_CONFIG"
        rm -f "$CF_CONFIG_BACKUP"
        echo -e "${YELLOW}[ROLLBACK]${RESET} Restored $CF_CONFIG from backup"
    fi

    # Reload Apache with restored config
    apache2ctl configtest &>/dev/null && systemctl reload apache2 &>/dev/null || true

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
    echo -e "  ${BOLD}VHost conf :${RESET} ${CONF_FILE:-n/a}"
    echo -e "  ${BOLD}ports.conf :${RESET} $PORTS_CONF"
    [[ -n "$CF_CONFIG" ]] && echo -e "  ${BOLD}CF config  :${RESET} $CF_CONFIG"
    echo ""
    echo -e "  ${BOLD}Actions performed:${RESET}"
    for entry in "${REPORT[@]}"; do
        echo "    $entry"
    done
    echo ""
    echo -e "${GREEN}  Done! ${BOLD}${SUBDOMAIN:-n/a}${RESET}${GREEN} has been removed from Apache.${RESET}"
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
echo "  ║       Apache Subdomain Remover — RPi5 LAMP       ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"

# =============================================================================
# STEP 1 — Select domain to remove
# =============================================================================
header "STEP 1 — Select Domain to Remove"

mapfile -t CONF_FILES < <(find "$SITES_AVAILABLE" -maxdepth 1 -name "*.conf" \
    ! -name "000-default.conf" ! -name "default-ssl.conf" | sort)

if [[ ${#CONF_FILES[@]} -eq 0 ]]; then
    die "No custom site configs found in $SITES_AVAILABLE"
fi

echo ""
echo -e "  ${BOLD}Available sites:${RESET}"
for i in "${!CONF_FILES[@]}"; do
    printf "    [%d] %s\n" "$((i+1))" "$(basename "${CONF_FILES[$i]}" .conf)"
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

# Extract port from <VirtualHost *:PORT> or <VirtualHost 127.0.0.1:PORT>
PORT=$(grep -oP '(?<=<VirtualHost )[^>]+(?=>)' "$CONF_FILE" | head -1 | grep -oP '\d+$' || true)
if [[ -z "$PORT" ]]; then
    die "Cannot find port in $CONF_FILE (expected '<VirtualHost *:PORT>' or '<VirtualHost IP:PORT>') — aborting."
fi
log "Port found in vhost config: $PORT"

# Extract DocumentRoot for display purposes only
DOCROOT=$(awk '/^\s*DocumentRoot\s+/{print $2; exit}' "$CONF_FILE" | xargs || true)
[[ -z "$DOCROOT" ]] && warn "DocumentRoot not found in $CONF_FILE — cannot display it in report"

# Find the exact Listen line for this port in ports.conf
LISTEN_LINE=$(grep -E "^\s*Listen\s+(\S+:)?${PORT}\s*$" "$PORTS_CONF" | head -1 | sed 's/[[:space:]]*$//' || true)
LISTEN_FOUND=false
if [[ -z "$LISTEN_LINE" ]]; then
    warn "No Listen directive for port $PORT found in $PORTS_CONF — skipping ports.conf cleanup"
else
    LISTEN_FOUND=true
    log "Found in ports.conf: '$LISTEN_LINE'"
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
if [[ "$LISTEN_FOUND" == "true" ]]; then
    printf "    ${RED}✖${RESET}  Listen directive  →  '%s'  from %s\n" "$LISTEN_LINE" "$PORTS_CONF"
else
    printf "    ${YELLOW}⚠${RESET}  Listen directive  →  port %s not in %s (already removed — skipping)\n" "$PORT" "$PORTS_CONF"
fi
printf "    ${RED}✖${RESET}  VirtualHost config →  %s\n" "$CONF_FILE"
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
echo -e "  ${BOLD}${RED}This will permanently remove Apache config for: ${SUBDOMAIN}${RESET}"
echo ""
read -rp "$(echo -e "  ${BOLD}Type 'yes' to proceed, anything else to abort:${RESET} ")" CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo -e "\n${YELLOW}Aborted. No changes were made.${RESET}\n"
    trap - EXIT
    exit 0
fi

# =============================================================================
# STEP 5 — Execute (backup-first, abort on any unexpected state)
# =============================================================================
header "STEP 5 — Removing Configuration"

# — Backup ports.conf (only if we have a Listen line to remove) —
if [[ "$LISTEN_FOUND" == "true" ]]; then
    PORTS_CONF_BACKUP="${PORTS_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$PORTS_CONF" "$PORTS_CONF_BACKUP"
    log "Backed up $PORTS_CONF → $PORTS_CONF_BACKUP"
fi

# — Backup vhost conf (so rollback can restore it if a later step fails) —
CONF_FILE_BACKUP="${CONF_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
cp "$CONF_FILE" "$CONF_FILE_BACKUP"
log "Backed up $CONF_FILE → $CONF_FILE_BACKUP"

# — Disable site —
if a2dissite "${SUBDOMAIN}.conf" &>/dev/null; then
    A2DISSITE_DONE=true
    ok "Disabled site via a2dissite"
else
    log "a2dissite returned non-zero — site may have already been disabled, continuing"
fi

# — Remove Listen directive from ports.conf —
if [[ "$LISTEN_FOUND" == "true" ]]; then
    LISTEN_LINE_NUM=$(grep -nE "^\s*Listen\s+(\S+:)?${PORT}\s*$" "$PORTS_CONF" | head -1 | cut -d: -f1 || true)
    if [[ -z "$LISTEN_LINE_NUM" ]]; then
        die "Listen directive for port $PORT not found in $PORTS_CONF — cannot remove it"
    fi
    sed -i "${LISTEN_LINE_NUM}d" "$PORTS_CONF"
    if grep -qE "^\s*Listen\s+(\S+:)?${PORT}\s*$" "$PORTS_CONF"; then
        die "Listen $PORT still present in $PORTS_CONF after deletion attempt"
    fi
    ok "Removed '$LISTEN_LINE' from $PORTS_CONF"
else
    warn "Skipped ports.conf — no Listen directive was present for port $PORT"
fi

# — Delete vhost conf —
rm -f "$CONF_FILE"
ok "Removed $CONF_FILE"
# CONF_FILE_BACKUP intentionally kept on disk until success so rollback can restore

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

    # Remove the hostname line; if the next line is a service line, remove that too
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

# — Apache configtest & restart —
log "Testing Apache configuration..."
if ! apache2ctl configtest 2>&1; then
    die "Apache config test failed after removal"
fi
ok "Apache config test passed"

log "Restarting Apache..."
if ! systemctl restart apache2; then
    die "Apache failed to restart"
fi
ok "Apache restarted"

# All succeeded — disarm trap and clean up backups
trap - EXIT
rm -f "$PORTS_CONF_BACKUP"
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
