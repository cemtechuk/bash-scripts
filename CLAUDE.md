# CLAUDE.md — Webserver Scripts (RPi5 LAMP)

## Git workflow — mandatory

**After every file change, commit and push to origin/master.**

```bash
git add <file>
git commit -m "Short description of what changed"
git push origin master
```

Remote: `https://github.com/cemtechuk/bash-scripts.git`

---

## Scripts

### create-subdomain.sh
Interactive wizard run as root. Creates an Apache VirtualHost for a new subdomain or domain on the RPi5.

**Steps performed:**
1. Prompts for full hostname (e.g. `app.example.com`)
2. Reads existing `Listen` ports from `ports.conf`, suggests next port ≥ 8000
3. Creates document root + placeholder `index.html` if missing; sets `www-data` ownership
4. Inserts new `Listen` directive into `ports.conf` — only looks for insertion points **before the first `<IfModule>` block** to avoid landing inside the SSL IfModule sections
5. Writes VirtualHost config to `/etc/apache2/sites-available/<hostname>.conf`
6. Runs `a2ensite`, `apache2ctl configtest`, and `systemctl restart apache2` — full rollback on failure
7. Optionally adds an ingress rule to the Cloudflare Tunnel config and sets `CF_NEEDS_RESTART=true`

**Rollback:** covers `ports.conf` (restored from timestamped backup), vhost conf, and docroot if they were created this run.

**Cloudflare restart deferral:** `systemctl restart cloudflared` is intentionally run **after** `print_report` so the full output is visible before the tunnel drops. The flag `CF_NEEDS_RESTART` controls this.

**Known issues / resolved:**
- ~~Listen directive landing inside `<IfModule ssl_module>` block~~ — fixed by scoping grep to lines before the first `<IfModule`
- ~~cloudflared restart dropping tunnel before user sees report~~ — fixed by deferring restart after `print_report`

---

### create-mariadb.sh
Non-interactive, takes arguments. Creates a MariaDB database + user with localhost and remote access.

**Usage:**
```bash
sudo bash create-mariadb.sh <db_name> <db_user> <db_password> [allowed_host]
```

- `allowed_host` defaults to `%` (any host)
- Set `MYSQL_ROOT_PASSWORD` env var to skip the root password prompt
- Rolls back (drops DB and both user entries) on any failure via `trap rollback ERR`
- Warns if `bind-address = 127.0.0.1` in MariaDB config (would block remote connections)
- Warns if UFW is active with no port 3306 rule

---

### delete-gz-logs.sh
One-liner. Recursively deletes all `.gz` compressed log files under `/var/log/`.

```bash
sudo bash delete-gz-logs.sh
```

No options, no rollback — destructive by design.

---

## Environment

- Hardware: Raspberry Pi 5
- Stack: Apache2, MariaDB, PHP (LAMP)
- Tunnel: Cloudflare Tunnel (`cloudflared`) — tunnel config at one of:
  - `/etc/cloudflared/config.yml`
  - `/root/.cloudflared/config.yml`
  - `~/.cloudflared/config.yml`
- Apache ports config: `/etc/apache2/ports.conf`
- Apache sites: `/etc/apache2/sites-available/`
