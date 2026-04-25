#!/bin/bash
# =============================================================================
# create-subdomain.sh — Apache Subdomain Creator for Raspberry Pi 5 LAMP Server
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
CONF_FILE_CREATED=false
DOCROOT_CREATED=false
DOCROOT=""
CONF_FILE=""

log()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET}    $*"; REPORT+=("✔ $*"); }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; REPORT+=("⚠ $*"); }
err()    { echo -e "${RED}[ERROR]${RESET} $*" >&2; REPORT+=("✖ $*"); }
header() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }

# ── Rollback on failure ───────────────────────────────────────────────────────
rollback() {
    echo -e "\n${RED}${BOLD}!! FAILURE DETECTED — Rolling back changes...${RESET}"

    # Restore ports.conf from backup
    if [[ -n "$PORTS_CONF_BACKUP" && -f "$PORTS_CONF_BACKUP" ]]; then
        cp "$PORTS_CONF_BACKUP" "$PORTS_CONF"
        rm -f "$PORTS_CONF_BACKUP"
        echo -e "${YELLOW}[ROLLBACK]${RESET} Restored $PORTS_CONF from backup"
    fi

    # Remove the vhost conf if we created it
    if [[ "$CONF_FILE_CREATED" == "true" && -n "$CONF_FILE" && -f "$CONF_FILE" ]]; then
        a2dissite "$(basename "$CONF_FILE")" &>/dev/null || true
        rm -f "$CONF_FILE"
        echo -e "${YELLOW}[ROLLBACK]${RESET} Removed $CONF_FILE"
    fi

    # Remove docroot only if we created it this run
    if [[ "$DOCROOT_CREATED" == "true" && -n "$DOCROOT" && -d "$DOCROOT" ]]; then
        rm -rf "$DOCROOT"
        echo -e "${YELLOW}[ROLLBACK]${RESET} Removed $DOCROOT"
    fi

    # Attempt to reload apache with previous config
    apache2ctl configtest &>/dev/null && systemctl reload apache2 &>/dev/null || true

    echo -e "${RED}Rollback complete. No permanent changes were made.${RESET}\n"
}

# Trap any error or exit-on-failure → rollback
trap 'EXIT_CODE=$?; if [[ $EXIT_CODE -ne 0 ]]; then rollback; fi' EXIT

# CTRL+C / SIGTERM → print message then exit with non-zero so EXIT trap fires rollback
trap 'echo -e "\n${YELLOW}Interrupted by user.${RESET}"; exit 130' INT TERM

die() {
    err "$*"
    exit 1   # triggers trap → rollback
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
    echo -e "  ${BOLD}DocRoot    :${RESET} ${DOCROOT:-n/a}"
    echo -e "  ${BOLD}VHost conf :${RESET} ${CONF_FILE:-n/a}"
    echo -e "  ${BOLD}ports.conf :${RESET} $PORTS_CONF"
    [[ -n "${CF_CONFIG:-}" ]] && echo -e "  ${BOLD}CF config  :${RESET} $CF_CONFIG"
    echo ""
    echo -e "  ${BOLD}Actions performed:${RESET}"
    for entry in "${REPORT[@]}"; do
        echo "    $entry"
    done
    echo ""
    echo -e "  ${BOLD}Quick tests:${RESET}"
    echo -e "    curl -s http://localhost:${PORT:-?}/ | head -5"
    echo -e "    apache2ctl -S 2>&1 | grep '${PORT:-?}'"
    echo ""
    echo -e "${GREEN}  Done! Your subdomain ${BOLD}${SUBDOMAIN:-n/a}${RESET}${GREEN} is ready on port ${PORT:-n/a}.${RESET}"
    echo ""
}

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║      Apache Subdomain Creator — RPi5 LAMP        ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"

# =============================================================================
# STEP 1 — Subdomain name
# =============================================================================
header "STEP 1 — Subdomain Details"

# Try to suggest the main domain from existing Apache ServerName or system hostname
DETECTED_DOMAIN=$(grep -rhE '^\s*ServerName\s+\S+' /etc/apache2/sites-enabled/ 2>/dev/null \
    | grep -oE '[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' | grep -v '^www\.' | head -1 || true)
[[ -z "$DETECTED_DOMAIN" ]] && DETECTED_DOMAIN=$(hostname -f 2>/dev/null || true)

while true; do
    read -rp "$(echo -e "${BOLD}Enter the full hostname${RESET} (subdomain or domain, e.g. app.example.com): ")" SUBDOMAIN
    SUBDOMAIN="${SUBDOMAIN// /}"
    if [[ -z "$SUBDOMAIN" ]]; then
        echo ""
        echo -e "${YELLOW}  No hostname entered.${RESET}"
        DOMAIN_HINT=""
        [[ -n "$DETECTED_DOMAIN" ]] && DOMAIN_HINT=" (detected: ${BOLD}${DETECTED_DOMAIN}${RESET})"
        read -rp "$(echo -e "  Did you mean to create a VirtualHost for the ${BOLD}main domain${RESET}${DOMAIN_HINT}? [Y/n]: ")" MAIN_CONFIRM
        if [[ "${MAIN_CONFIRM,,}" == "n" ]]; then
            echo ""
            continue   # loop back and ask for the hostname again
        fi
        # Ask for / confirm the main domain
        read -rp "$(echo -e "  Enter your main domain${DETECTED_DOMAIN:+ [${DETECTED_DOMAIN}]}: ")" MAIN_DOMAIN_INPUT
        SUBDOMAIN="${MAIN_DOMAIN_INPUT:-$DETECTED_DOMAIN}"
        SUBDOMAIN="${SUBDOMAIN// /}"
        if [[ -z "$SUBDOMAIN" ]]; then
            warn "No domain provided. Please enter a hostname."
            continue
        fi
        if [[ ! "$SUBDOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
            warn "Invalid domain format: '$SUBDOMAIN'. Please try again."
            continue
        fi
        echo ""
        ok "Using main domain: $SUBDOMAIN"
        break
    elif [[ ! "$SUBDOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
        warn "Invalid hostname format. Please try again."
    else
        break
    fi
done
ok "Hostname set to: $SUBDOMAIN"
REPORT+=("  Hostname : $SUBDOMAIN")

# =============================================================================
# STEP 2 — Port selection
# =============================================================================
header "STEP 2 — Port Assignment"

if [[ ! -f "$PORTS_CONF" ]]; then
    die "$PORTS_CONF not found. Is Apache installed?"
fi

# Match both "Listen 8080" and "Listen 127.0.0.1:8080" formats
# Extract just the port number from each matching line
USED_PORTS=$(grep -E '^\s*Listen\s+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:)?[0-9]+\s*$' "$PORTS_CONF" \
    | grep -oE '[0-9]+$' | sort -n)
log "Existing Listen ports in $PORTS_CONF:"
echo "$USED_PORTS" | while read -r p; do echo "    • $p"; done

# Detect the IP prefix used in existing Listen directives (e.g. "127.0.0.1:")
LISTEN_IP_PREFIX=$(grep -E '^\s*Listen\s+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+' "$PORTS_CONF" \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:' | head -1)
# LISTEN_IP_PREFIX will be "127.0.0.1:" or empty (bare port style)

# Find the highest port that looks like a local-app port (>= 8000, < 65535)
LAST_APP_PORT=$(echo "$USED_PORTS" | awk '$1>=8000 && $1<65535 {last=$1} END {print last+0}')

if [[ "$LAST_APP_PORT" -lt 8000 ]]; then
    SUGGESTED_PORT=8080
else
    SUGGESTED_PORT=$(( LAST_APP_PORT + 1 ))
fi

log "Last detected app port: ${LAST_APP_PORT:-none}  →  Suggested next port: $SUGGESTED_PORT"

read -rp "$(echo -e "${BOLD}Use port ${SUGGESTED_PORT}?${RESET} [Y/n or enter a custom port]: ")" PORT_INPUT
PORT_INPUT="${PORT_INPUT// /}"

if [[ -z "$PORT_INPUT" || "${PORT_INPUT,,}" == "y" ]]; then
    PORT="$SUGGESTED_PORT"
elif [[ "$PORT_INPUT" =~ ^[0-9]+$ ]]; then
    PORT="$PORT_INPUT"
else
    die "Invalid port input: '$PORT_INPUT'"
fi

if [[ "$PORT" -lt 1 || "$PORT" -gt 65535 ]]; then
    die "Port $PORT is out of valid range (1–65535)."
fi

if ss -tlnp | grep -q ":${PORT}\b"; then
    warn "Something is already listening on port $PORT. Proceeding anyway — check for conflicts."
fi

ok "Port selected: $PORT"
REPORT+=("  Port     : $PORT")

# =============================================================================
# STEP 3 — Document root
# =============================================================================
header "STEP 3 — Document Root"

DEFAULT_DOCROOT="/var/www/${SUBDOMAIN}"
IS_FRAMEWORK=false

read -rp "$(echo -e "${BOLD}Framework project (Laravel, CodeIgniter, etc.)?${RESET} [y/N]: ")" FW_CONFIRM
if [[ "${FW_CONFIRM,,}" == "y" ]]; then
    DEFAULT_DOCROOT="${DEFAULT_DOCROOT}/public"
    IS_FRAMEWORK=true
    log "Framework mode — document root will point to /public subfolder"
fi

read -rp "$(echo -e "${BOLD}Document root${RESET} [${DEFAULT_DOCROOT}]: ")" DOCROOT_INPUT
DOCROOT="${DOCROOT_INPUT:-$DEFAULT_DOCROOT}"
DOCROOT="${DOCROOT%/}"

if [[ ! -d "$DOCROOT" ]]; then
    read -rp "$(echo -e "${YELLOW}Directory does not exist. Create it?${RESET} [Y/n]: ")" MKDIR_CONFIRM
    if [[ "${MKDIR_CONFIRM,,}" != "n" ]]; then
        mkdir -p "$DOCROOT"
        DOCROOT_CREATED=true
        if [[ "$IS_FRAMEWORK" == "false" ]]; then
            cat > "$DOCROOT/index.html" <<HTML
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><title>${SUBDOMAIN}</title></head>
<body>
  <h1>${SUBDOMAIN}</h1>
  <p>Apache VirtualHost is working.</p>
</body>
</html>
HTML
        fi
        chown -R www-data:www-data "$DOCROOT"
        ok "Created document root: $DOCROOT"
    else
        warn "Document root not created. Make sure it exists before starting Apache."
    fi
else
    ok "Document root exists: $DOCROOT"
fi
REPORT+=("  DocRoot  : $DOCROOT")

# =============================================================================
# STEP 4 — Write ports.conf entry (inserted after last Listen line)
# =============================================================================
header "STEP 4 — Updating ports.conf"

# Backup ports.conf before touching it
PORTS_CONF_BACKUP="${PORTS_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
cp "$PORTS_CONF" "$PORTS_CONF_BACKUP"
log "Backed up ports.conf to $PORTS_CONF_BACKUP"

# Build the Listen directive in the same format as existing ones
NEW_LISTEN="Listen ${LISTEN_IP_PREFIX}${PORT}"

if grep -qE "^\s*Listen\s+(\S+:)?${PORT}\s*$" "$PORTS_CONF"; then
    warn "Port $PORT already in $PORTS_CONF — skipping."
else
    # Find the last Listen directive that sits outside any <IfModule> block
    # (Listen 443 lines inside <IfModule ssl_module> / mod_gnutls.c must not be used as insertion points)
    FIRST_IFMODULE=$(grep -n '<IfModule' "$PORTS_CONF" | head -1 | cut -d: -f1)

    if [[ -n "$FIRST_IFMODULE" ]]; then
        # Only consider Listen lines before the first <IfModule block
        LAST_LISTEN_LINE=$(head -n "$((FIRST_IFMODULE - 1))" "$PORTS_CONF" \
            | grep -nE '^\s*Listen\s+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:)?[0-9]+\s*$' \
            | tail -1 | cut -d: -f1)
    else
        LAST_LISTEN_LINE=$(grep -nE '^\s*Listen\s+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:)?[0-9]+\s*$' "$PORTS_CONF" \
            | tail -1 | cut -d: -f1)
    fi

    if [[ -n "$LAST_LISTEN_LINE" ]]; then
        sed -i "${LAST_LISTEN_LINE}a ${NEW_LISTEN}" "$PORTS_CONF"
        ok "Inserted '$NEW_LISTEN' after line $LAST_LISTEN_LINE in $PORTS_CONF"
    elif [[ -n "$FIRST_IFMODULE" ]]; then
        INSERT_AT=$(( FIRST_IFMODULE - 1 ))
        sed -i "${INSERT_AT}a ${NEW_LISTEN}" "$PORTS_CONF"
        ok "Inserted '$NEW_LISTEN' before <IfModule at line $FIRST_IFMODULE in $PORTS_CONF"
    else
        die "Could not find a safe insertion point in $PORTS_CONF. Please add '$NEW_LISTEN' manually."
    fi
fi

# =============================================================================
# STEP 5 — Write VirtualHost config
# =============================================================================
header "STEP 5 — Creating VirtualHost Config"

CONF_FILE="${SITES_AVAILABLE}/${SUBDOMAIN}.conf"
CREATE_VHOST=false

if [[ -f "$CONF_FILE" ]]; then
    warn "Config file $CONF_FILE already exists."
    read -rp "$(echo -e "${YELLOW}Overwrite it?${RESET} [y/N]: ")" OW_CONFIRM
    if [[ "${OW_CONFIRM,,}" == "y" ]]; then
        CREATE_VHOST=true
    else
        log "Skipping VirtualHost creation. Using existing config."
    fi
else
    CREATE_VHOST=true
fi

if [[ "$CREATE_VHOST" == "true" ]]; then
    cat > "$CONF_FILE" <<APACHECONF
<VirtualHost *:${PORT}>
    ServerName   ${SUBDOMAIN}
    DocumentRoot ${DOCROOT}

    <Directory ${DOCROOT}>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog  \${APACHE_LOG_DIR}/${SUBDOMAIN}-error.log
    CustomLog \${APACHE_LOG_DIR}/${SUBDOMAIN}-access.log combined
</VirtualHost>
APACHECONF
    CONF_FILE_CREATED=true
    ok "VirtualHost config written to $CONF_FILE"
fi
REPORT+=("  Config   : $CONF_FILE")

# =============================================================================
# STEP 6 — Enable site, syntax check, restart
# =============================================================================
header "STEP 6 — Enabling Site & Restarting Apache"

log "Running a2ensite..."
a2ensite "${SUBDOMAIN}.conf" 2>&1 || warn "a2ensite returned non-zero — site may already be enabled."
ok "Site enabled via a2ensite"

log "Checking Apache config syntax..."
echo ""
# Run configtest; on failure the trap will rollback
if ! apache2ctl configtest 2>&1; then
    die "Apache syntax check FAILED — rolling back all changes."
fi
ok "Apache syntax check passed"

log "Restarting Apache..."
if ! systemctl restart apache2; then
    die "Apache failed to restart — rolling back all changes."
fi
ok "Apache restarted successfully"

log "Apache service status:"
echo ""
systemctl status apache2 --no-pager -l | head -30
echo ""

# All good — disarm the rollback trap
PORTS_CONF_BACKUP_KEEP="$PORTS_CONF_BACKUP"
PORTS_CONF_BACKUP=""          # prevents rollback from restoring it on normal exit
CONF_FILE_CREATED=false       # prevents rollback from removing it on normal exit
DOCROOT_CREATED=false

# Clean up the ports.conf backup since we succeeded
rm -f "$PORTS_CONF_BACKUP_KEEP"

# =============================================================================
# STEP 7 — Cloudflare Tunnel (optional)
# =============================================================================
header "STEP 7 — Cloudflare Tunnel Integration"

CF_CONFIG=""
CF_NEEDS_RESTART=false

if ! command -v cloudflared &>/dev/null; then
    log "cloudflared is not installed — skipping."
    REPORT+=("  Cloudflare: not installed — skipped")
else
    for candidate in "${CF_CONFIG_CANDIDATES[@]}"; do
        if [[ -f "$candidate" ]]; then
            CF_CONFIG="$candidate"
            break
        fi
    done

    if [[ -z "$CF_CONFIG" ]] || ! grep -q '^ingress:' "$CF_CONFIG" 2>/dev/null; then
        log "cloudflared is installed but no tunnel is configured — skipping."
        REPORT+=("  Cloudflare: no tunnel configured — skipped")
    else
        log "Found cloudflared config at: $CF_CONFIG"
        echo ""
        log "Current ingress rules:"
        grep -A 100 '^ingress:' "$CF_CONFIG" || true
        echo ""

        read -rp "$(echo -e "${BOLD}Add ${SUBDOMAIN} to this Cloudflare tunnel?${RESET} [Y/n]: ")" CF_CONFIRM
        if [[ "${CF_CONFIRM,,}" == "n" ]]; then
            log "Skipping Cloudflare tunnel integration."
            REPORT+=("  Cloudflare: skipped by user")
        else
            CF_BACKUP="${CF_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"
            cp "$CF_CONFIG" "$CF_BACKUP"
            ok "Backed up cloudflared config to $CF_BACKUP"

            if grep -q "hostname: ${SUBDOMAIN}" "$CF_CONFIG"; then
                warn "Hostname $SUBDOMAIN already exists in $CF_CONFIG — skipping."
                REPORT+=("  Cloudflare: hostname already present — skipped")
            else
                # Insert before the catch-all (last entry with no hostname)
                CATCHALL_LINE=$(awk '/^ingress:/{found=1} found && /^\s+-\s+service:/{last=NR} END{print last+0}' "$CF_CONFIG")

                if [[ "$CATCHALL_LINE" -gt 0 ]]; then
                    sed -i "${CATCHALL_LINE}i\\  - hostname: ${SUBDOMAIN}\\n    service: http://localhost:${PORT}" "$CF_CONFIG"
                    ok "Inserted ingress rule for $SUBDOMAIN before catch-all (line $CATCHALL_LINE)"
                else
                    printf "  - hostname: %s\n    service: http://localhost:%s\n" "$SUBDOMAIN" "$PORT" >> "$CF_CONFIG"
                    warn "No catch-all detected — appended rule. Review $CF_CONFIG manually."
                fi

                REPORT+=("  Cloudflare: ingress rule added for $SUBDOMAIN → localhost:${PORT}")
                REPORT+=("  Cloudflare: service restart deferred until after report")
                CF_NEEDS_RESTART=true

                log "Updated ingress rules:"
                grep -A 100 '^ingress:' "$CF_CONFIG" || true
            fi
        fi
    fi
fi

# =============================================================================
# FINAL REPORT
# =============================================================================
print_report

# Restart cloudflared after the report — if connected via the tunnel, restarting
# earlier would drop the connection before the user could read the output
if [[ "$CF_NEEDS_RESTART" == "true" ]]; then
    warn "Restarting cloudflared now — if you are connected via the tunnel, your connection will drop momentarily."
    if systemctl restart cloudflared 2>/dev/null; then
        echo -e "${GREEN}[OK]${RESET}    cloudflared restarted successfully"
    else
        echo -e "${YELLOW}[WARN]${RESET}  Could not restart cloudflared (check 'systemctl status cloudflared')."
    fi
fi
