#!/bin/bash
# =============================================================================
# create-subdomain-nginx.sh — Nginx Subdomain Creator for Raspberry Pi 5
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
NGINX_CONF_CREATED=false
INCLUDE_ADDED=false
DOCROOT_CREATED=false
DOCROOT=""
BASE_DOCROOT=""
NGINX_CONF=""
FRAMEWORK="none"
FW_PUBLIC_DIR=""
IS_FRAMEWORK=false
DEPLOY_SCRIPT=""
GIT_REMOTE_DISPLAY=""

log()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET}    $*"; REPORT+=("✔ $*"); }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; REPORT+=("⚠ $*"); }
err()    { echo -e "${RED}[ERROR]${RESET} $*" >&2; REPORT+=("✖ $*"); }
header() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }

# ── Rollback on failure ───────────────────────────────────────────────────────
rollback() {
    echo -e "\n${RED}${BOLD}!! FAILURE DETECTED — Rolling back changes...${RESET}"

    # Remove the include line we appended to sites.conf
    if [[ "$INCLUDE_ADDED" == "true" && -n "$NGINX_CONF" ]]; then
        ESCAPED=$(echo "$NGINX_CONF" | sed 's|/|\\/|g')
        sed -i "/include ${ESCAPED};/d" "$SITES_CONF" 2>/dev/null || true
        echo -e "${YELLOW}[ROLLBACK]${RESET} Removed include directive from $SITES_CONF"
    fi

    # Restore sites.conf from backup (catches any partial edits)
    if [[ -n "$SITES_CONF_BACKUP" && -f "$SITES_CONF_BACKUP" ]]; then
        cp "$SITES_CONF_BACKUP" "$SITES_CONF"
        rm -f "$SITES_CONF_BACKUP"
        echo -e "${YELLOW}[ROLLBACK]${RESET} Restored $SITES_CONF from backup"
    fi

    # Remove nginx.conf from project root if we created it
    if [[ "$NGINX_CONF_CREATED" == "true" && -n "$NGINX_CONF" && -f "$NGINX_CONF" ]]; then
        rm -f "$NGINX_CONF"
        echo -e "${YELLOW}[ROLLBACK]${RESET} Removed $NGINX_CONF"
    fi

    # Remove docroot only if we created it this run
    if [[ "$DOCROOT_CREATED" == "true" && -n "$DOCROOT" && -d "$DOCROOT" ]]; then
        rm -rf "$DOCROOT"
        echo -e "${YELLOW}[ROLLBACK]${RESET} Removed $DOCROOT"
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
    echo -e "  ${BOLD}Framework  :${RESET} ${FRAMEWORK:-none}"
    echo -e "  ${BOLD}DocRoot    :${RESET} ${DOCROOT:-n/a}"
    echo -e "  ${BOLD}nginx conf :${RESET} ${NGINX_CONF:-n/a}"
    echo -e "  ${BOLD}sites.conf :${RESET} $SITES_CONF"
    [[ -n "${DEPLOY_SCRIPT:-}" ]] && echo -e "  ${BOLD}Deploy     :${RESET} $DEPLOY_SCRIPT"
    [[ -n "${CF_CONFIG:-}" ]] && echo -e "  ${BOLD}CF config  :${RESET} $CF_CONFIG"
    [[ -n "${GIT_REMOTE_DISPLAY:-}" ]] && echo -e "  ${BOLD}Git remote :${RESET} $GIT_REMOTE_DISPLAY"
    echo ""
    echo -e "  ${BOLD}Actions performed:${RESET}"
    for entry in "${REPORT[@]}"; do
        echo "    $entry"
    done
    echo ""
    echo -e "  ${BOLD}Quick tests:${RESET}"
    echo -e "    curl -s http://localhost:${PORT:-?}/"
    echo -e "    nginx -T 2>&1 | grep '${SUBDOMAIN:-?}'"
    echo ""
    echo -e "${GREEN}  Done! Your subdomain ${BOLD}${SUBDOMAIN:-n/a}${RESET}${GREEN} is ready on port ${PORT:-n/a}.${RESET}"
    echo ""
}

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

# ── Sanity check ──────────────────────────────────────────────────────────────
[[ -d "/etc/nginx/conf.d" ]] || die "/etc/nginx/conf.d not found — is nginx installed?"

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║       Nginx Subdomain Creator — RPi5             ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"

# =============================================================================
# STEP 1 — Subdomain name
# =============================================================================
header "STEP 1 — Subdomain Details"

DETECTED_DOMAIN=$(grep -rhE '^\s*server_name\s+\S+' /etc/nginx/conf.d/ 2>/dev/null \
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
        read -rp "$(echo -e "  Did you mean to create a server block for the ${BOLD}main domain${RESET}${DOMAIN_HINT}? [Y/n]: ")" MAIN_CONFIRM
        if [[ "${MAIN_CONFIRM,,}" == "n" ]]; then
            echo ""
            continue
        fi
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

# Scan all included nginx.conf files listed in sites.conf for used ports
USED_PORTS=""
if [[ -f "$SITES_CONF" ]]; then
    while IFS= read -r inc_path; do
        [[ -f "$inc_path" ]] && USED_PORTS+=$'\n'"$(grep -E '^\s*listen\s+' "$inc_path" 2>/dev/null \
            | grep -oE '\b[0-9]{1,5}\b' || true)"
    done < <(grep -E '^\s*include\s+' "$SITES_CONF" | awk '{print $2}' | tr -d ';')
fi
USED_PORTS=$(echo "$USED_PORTS" | sort -nu | grep -v '^$' || true)

log "Existing listen ports found across managed sites:"
echo "$USED_PORTS" | while read -r p; do [[ -n "$p" ]] && echo "    • $p"; done

SUGGESTED_PORT=$(echo "$USED_PORTS" | awk '
    $1 >= 8000 && $1 < 65535 { ports[$1] = 1; count++ }
    END {
        if (count == 0) { print 8080; exit }
        min = 65535
        for (p in ports) if (p + 0 < min) min = p + 0
        for (p = min; p < 65535; p++) {
            if (!(p in ports)) { print p; exit }
        }
    }
')
[[ -z "$SUGGESTED_PORT" ]] && SUGGESTED_PORT=8080

log "Suggested next available port: $SUGGESTED_PORT"

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
# STEP 3 — Document root & framework
# =============================================================================
header "STEP 3 — Document Root"

DEFAULT_BASE_DOCROOT="/var/www/${SUBDOMAIN}"

echo ""
echo -e "  ${BOLD}Select framework:${RESET}"
echo "    1) Laravel"
echo "    2) CodeIgniter 4"
echo "    3) Symfony"
echo "    4) CakePHP"
echo "    5) None (plain PHP / static)"
echo ""
read -rp "$(echo -e "${BOLD}Framework${RESET} [1-5, default 5]: ")" FW_INPUT
case "${FW_INPUT:-5}" in
    1) FRAMEWORK="laravel";     FW_PUBLIC_DIR="public";  IS_FRAMEWORK=true
       log "Framework: Laravel — docroot → /public" ;;
    2) FRAMEWORK="codeigniter"; FW_PUBLIC_DIR="public";  IS_FRAMEWORK=true
       log "Framework: CodeIgniter 4 — docroot → /public" ;;
    3) FRAMEWORK="symfony";     FW_PUBLIC_DIR="public";  IS_FRAMEWORK=true
       log "Framework: Symfony — docroot → /public" ;;
    4) FRAMEWORK="cakephp";     FW_PUBLIC_DIR="webroot"; IS_FRAMEWORK=true
       log "Framework: CakePHP — docroot → /webroot" ;;
    *)  FRAMEWORK="none";        FW_PUBLIC_DIR="";        IS_FRAMEWORK=false
       log "No framework selected" ;;
esac

DEFAULT_DOCROOT="${DEFAULT_BASE_DOCROOT}${IS_FRAMEWORK:+/${FW_PUBLIC_DIR}}"

read -rp "$(echo -e "${BOLD}Document root${RESET} [${DEFAULT_DOCROOT}]: ")" DOCROOT_INPUT
DOCROOT="${DOCROOT_INPUT:-$DEFAULT_DOCROOT}"
DOCROOT="${DOCROOT%/}"

# Derive BASE_DOCROOT (project root, without framework public subdir)
if [[ "$IS_FRAMEWORK" == "true" ]]; then
    BASE_DOCROOT="${DOCROOT%/${FW_PUBLIC_DIR}}"
else
    BASE_DOCROOT="$DOCROOT"
fi

NGINX_CONF="${BASE_DOCROOT}/nginx.conf"

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
  <p>nginx server block is working.</p>
</body>
</html>
HTML
        fi
        chown -R www-data:www-data "$DOCROOT"
        ok "Created document root: $DOCROOT"
    else
        warn "Document root not created. Make sure it exists before nginx can serve it."
    fi
else
    ok "Document root exists: $DOCROOT"
fi
REPORT+=("  DocRoot  : $DOCROOT")

# =============================================================================
# STEP 4 — Write nginx.conf into project root
# =============================================================================
header "STEP 4 — Writing nginx.conf"

# Auto-detect PHP-FPM socket
PHP_FPM_SOCK=$(ls /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -1 || true)
if [[ -n "$PHP_FPM_SOCK" ]]; then
    log "Detected PHP-FPM socket: $PHP_FPM_SOCK"
else
    PHP_FPM_SOCK="/run/php/php-fpm.sock"
    warn "PHP-FPM socket not found — using placeholder: $PHP_FPM_SOCK"
fi

# Frameworks need the front-controller fallback; plain sites get a hard 404
if [[ "$IS_FRAMEWORK" == "true" ]]; then
    TRY_FILES="try_files \$uri \$uri/ /index.php?\$query_string;"
else
    TRY_FILES="try_files \$uri \$uri/ =404;"
fi

CREATE_CONF=false
if [[ -f "$NGINX_CONF" ]]; then
    warn "Config file $NGINX_CONF already exists."
    read -rp "$(echo -e "${YELLOW}Overwrite it?${RESET} [y/N]: ")" OW_CONFIRM
    [[ "${OW_CONFIRM,,}" == "y" ]] && CREATE_CONF=true || log "Skipping — using existing config."
else
    CREATE_CONF=true
fi

if [[ "$CREATE_CONF" == "true" ]]; then
    cat > "$NGINX_CONF" <<NGINXCONF
server {
    listen ${PORT};
    server_name ${SUBDOMAIN};
    root ${DOCROOT};
    index index.php index.html index.htm;

    location / {
        ${TRY_FILES}
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_FPM_SOCK};
    }

    location ~ /\.ht {
        deny all;
    }

    error_log  /var/log/nginx/${SUBDOMAIN}-error.log;
    access_log /var/log/nginx/${SUBDOMAIN}-access.log;
}
NGINXCONF
    chown "${SUDO_USER:-root}:www-data" "$NGINX_CONF"
    chmod 640 "$NGINX_CONF"
    NGINX_CONF_CREATED=true
    ok "Server block written to $NGINX_CONF"
fi
REPORT+=("  nginx conf : $NGINX_CONF")

# =============================================================================
# STEP 5 — Add include to sites.conf, syntax check, reload
# =============================================================================
header "STEP 5 — Registering in sites.conf & Reloading nginx"

# Backup sites.conf before touching it (create the file if it doesn't exist yet)
if [[ ! -f "$SITES_CONF" ]]; then
    touch "$SITES_CONF"
    ok "Created $SITES_CONF"
fi
SITES_CONF_BACKUP="${SITES_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
cp "$SITES_CONF" "$SITES_CONF_BACKUP"
log "Backed up $SITES_CONF → $SITES_CONF_BACKUP"

INCLUDE_LINE="include ${NGINX_CONF};"
if grep -qF "$INCLUDE_LINE" "$SITES_CONF"; then
    warn "Include for $NGINX_CONF already present in $SITES_CONF — skipping."
else
    echo "$INCLUDE_LINE" >> "$SITES_CONF"
    INCLUDE_ADDED=true
    ok "Appended '$INCLUDE_LINE' to $SITES_CONF"
fi
REPORT+=("  sites.conf : $SITES_CONF")

log "Checking nginx config syntax..."
echo ""
if ! nginx -t 2>&1; then
    die "nginx syntax check FAILED — rolling back all changes."
fi
ok "nginx syntax check passed"

log "Reloading nginx..."
if ! systemctl reload nginx; then
    die "nginx failed to reload — rolling back all changes."
fi
ok "nginx reloaded successfully"

log "nginx service status:"
echo ""
systemctl status nginx --no-pager -l | head -20
echo ""

# All good — disarm the rollback trap and clean up backup
NGINX_CONF_CREATED=false
INCLUDE_ADDED=false
DOCROOT_CREATED=false
rm -f "$SITES_CONF_BACKUP"
SITES_CONF_BACKUP=""

# =============================================================================
# STEP 6 — Deploy script
# =============================================================================
header "STEP 6 — Deploy Script"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/deploy.template.sh"
DEPLOY_USER="${SUDO_USER:-cem}"

if [[ ! -f "$TEMPLATE_FILE" ]]; then
    warn "deploy.template.sh not found at $TEMPLATE_FILE — deploy script not created."
    REPORT+=("  Deploy   : template not found — skipped")
elif [[ ! -d "$BASE_DOCROOT" ]]; then
    warn "Base docroot $BASE_DOCROOT does not exist — deploy script not created."
    REPORT+=("  Deploy   : docroot missing — skipped")
else
    DEPLOY_SCRIPT="${BASE_DOCROOT}/deploy.sh"
    cp "$TEMPLATE_FILE" "$DEPLOY_SCRIPT"
    sed -i "s|APP_DIR=\"/var/www/HOSTNAME\"|APP_DIR=\"${BASE_DOCROOT}\"|" "$DEPLOY_SCRIPT"
    sed -i "s|FRAMEWORK=\"none\"|FRAMEWORK=\"${FRAMEWORK}\"|" "$DEPLOY_SCRIPT"
    sed -i "s|APP_USER=\"cem\"|APP_USER=\"${DEPLOY_USER}\"|" "$DEPLOY_SCRIPT"
    chmod 750 "$DEPLOY_SCRIPT"
    chown "${DEPLOY_USER}:www-data" "$DEPLOY_SCRIPT"
    ok "Deploy script written to $DEPLOY_SCRIPT"
    REPORT+=("  Deploy   : $DEPLOY_SCRIPT")
fi

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
# STEP 8 — Git Repository
# =============================================================================
header "STEP 8 — Git Repository"

GIT_REPO_INITIALIZED=false

read -rp "$(echo -e "${BOLD}Initialise a git repository in ${BASE_DOCROOT}?${RESET} [Y/n]: ")" GIT_INIT_CONFIRM

if [[ "${GIT_INIT_CONFIRM,,}" != "n" ]]; then

    chown "${DEPLOY_USER}:www-data" "$BASE_DOCROOT"

    if [[ -d "${BASE_DOCROOT}/.git" ]]; then
        warn "Git repo already exists in ${BASE_DOCROOT} — skipping init."
        GIT_REPO_INITIALIZED=true
    else
        log "Initialising git repository in ${BASE_DOCROOT}..."

        if [[ ! -f "${BASE_DOCROOT}/.gitignore" ]]; then
            printf '.env\ndeploy.sh\n*.log\n/vendor/\n/node_modules/\n' > "${BASE_DOCROOT}/.gitignore"
            chown "${DEPLOY_USER}:www-data" "${BASE_DOCROOT}/.gitignore"
        fi

        if ! sudo -Hu "$DEPLOY_USER" git -C "$BASE_DOCROOT" init -b main 2>/dev/null; then
            sudo -Hu "$DEPLOY_USER" git -C "$BASE_DOCROOT" init
            sudo -Hu "$DEPLOY_USER" git -C "$BASE_DOCROOT" checkout -b main 2>/dev/null || true
        fi

        sudo -Hu "$DEPLOY_USER" git -C "$BASE_DOCROOT" add -A

        if sudo -Hu "$DEPLOY_USER" git -C "$BASE_DOCROOT" \
                commit -m "Initial commit — scaffold by create-subdomain-nginx.sh"; then
            ok "Git repo initialised with initial commit in ${BASE_DOCROOT}"
            REPORT+=("  Git      : repo initialised — ${BASE_DOCROOT}")
        else
            warn "Initial commit failed — git identity may not be configured for ${DEPLOY_USER}."
            warn "Fix: sudo -Hu ${DEPLOY_USER} git config --global user.name 'Your Name'"
            warn "Fix: sudo -Hu ${DEPLOY_USER} git config --global user.email 'you@example.com'"
            REPORT+=("  Git      : init OK, initial commit failed — configure git identity")
        fi
        GIT_REPO_INITIALIZED=true
    fi

    if [[ "$GIT_REPO_INITIALIZED" == "true" ]]; then
        echo ""
        read -rp "$(echo -e "${BOLD}Link to a remote GitHub repository?${RESET} [Y/n]: ")" GIT_REMOTE_CONFIRM

        if [[ "${GIT_REMOTE_CONFIRM,,}" != "n" ]]; then
            ENV_FILE="${SCRIPT_DIR}/.env"
            GITHUB_TOKEN=""

            if [[ -f "$ENV_FILE" ]]; then
                GITHUB_TOKEN=$(grep -E '^GITHUB_TOKEN=' "$ENV_FILE" 2>/dev/null \
                    | head -1 | cut -d'=' -f2- | sed "s/[[:space:]\"']//g")
            fi

            if [[ -z "$GITHUB_TOKEN" ]]; then
                echo -e "${YELLOW}  No GitHub token found in ${ENV_FILE}.${RESET}"
                IFS= read -rsp "  $(echo -e "${BOLD}GitHub Personal Access Token${RESET}") (input hidden): " GITHUB_TOKEN
                echo ""
                if [[ -n "$GITHUB_TOKEN" ]]; then
                    read -rp "  Save token to ${ENV_FILE} for future use? [Y/n]: " SAVE_TOKEN_CONFIRM
                    if [[ "${SAVE_TOKEN_CONFIRM,,}" != "n" ]]; then
                        touch "$ENV_FILE"
                        chmod 600 "$ENV_FILE"
                        if grep -q '^GITHUB_TOKEN=' "$ENV_FILE" 2>/dev/null; then
                            sed -i "s|^GITHUB_TOKEN=.*|GITHUB_TOKEN=${GITHUB_TOKEN}|" "$ENV_FILE"
                        else
                            echo "GITHUB_TOKEN=${GITHUB_TOKEN}" >> "$ENV_FILE"
                        fi
                        ok "Token saved to ${ENV_FILE}"
                        REPORT+=("  GitHub   : token saved to ${ENV_FILE}")
                    fi
                else
                    warn "No token entered — skipping remote setup."
                fi
            else
                log "GitHub token loaded from ${ENV_FILE}"
            fi

            if [[ -n "$GITHUB_TOKEN" ]]; then
                read -rp "  $(echo -e "${BOLD}Remote repo${RESET}") (e.g. username/repo-name): " REPO_INPUT
                REPO_INPUT="${REPO_INPUT// /}"
                REPO_PATH=$(echo "$REPO_INPUT" \
                    | sed 's|^https://github\.com/||; s|^github\.com/||; s|\.git$||')

                if [[ -z "$REPO_PATH" || ! "$REPO_PATH" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
                    warn "Invalid repo format (expected 'username/repo-name') — skipping remote."
                    REPORT+=("  Git remote: invalid input — skipped")
                else
                    GIT_REMOTE_DISPLAY="https://github.com/${REPO_PATH}.git"
                    REMOTE_URL="https://${GITHUB_TOKEN}@github.com/${REPO_PATH}.git"

                    log "Adding remote 'origin' → ${GIT_REMOTE_DISPLAY} (token auth)"
                    sudo -Hu "$DEPLOY_USER" git -C "$BASE_DOCROOT" remote remove origin 2>/dev/null || true

                    if sudo -Hu "$DEPLOY_USER" git -C "$BASE_DOCROOT" remote add origin "$REMOTE_URL"; then
                        log "Pushing to remote..."
                        if sudo -Hu "$DEPLOY_USER" git -C "$BASE_DOCROOT" push -u origin HEAD; then
                            ok "Pushed to ${GIT_REMOTE_DISPLAY}"
                            REPORT+=("  Git remote: ${GIT_REMOTE_DISPLAY}")
                        else
                            warn "Push failed — verify token has 'repo' scope and ${REPO_PATH} exists on GitHub."
                            REPORT+=("  Git remote: added, push failed — check token / repo exists")
                        fi
                    else
                        warn "Failed to add remote 'origin'."
                        REPORT+=("  Git remote: remote add failed")
                    fi
                fi
            fi
        else
            log "Skipping remote setup."
            REPORT+=("  Git      : local only, no remote")
        fi
    fi

else
    log "Skipping git repository setup."
    REPORT+=("  Git      : skipped")
fi

# =============================================================================
# FINAL REPORT
# =============================================================================
print_report

# Restart cloudflared after report — avoids dropping tunnel before user reads output
if [[ "$CF_NEEDS_RESTART" == "true" ]]; then
    warn "Restarting cloudflared now — if you are connected via the tunnel, your connection will drop momentarily."
    if systemctl restart cloudflared 2>/dev/null; then
        echo -e "${GREEN}[OK]${RESET}    cloudflared restarted successfully"
    else
        echo -e "${YELLOW}[WARN]${RESET}  Could not restart cloudflared (check 'systemctl status cloudflared')."
    fi
fi
