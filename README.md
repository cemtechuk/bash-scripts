# bash-scripts

Utility scripts for managing a Raspberry Pi 5 LAMP server.

---

## create-mariadb.sh

Creates a MariaDB database, user, and grants access from both localhost and a local network subnet. Rolls back all changes if any step fails.

```
sudo bash create-mariadb.sh <db_name> <db_user> <db_password> [allowed_host]
```

- `allowed_host` defaults to `192.168.1.%`
- Set `MYSQL_ROOT_PASSWORD` env var to skip the root password prompt
- Warns if MariaDB `bind-address` is `127.0.0.1` (blocks remote connections) or if UFW has no rule for port 3306

---

## create-subdomain.sh

Interactive wizard that creates an Apache VirtualHost for a new subdomain or domain. Must be run as root.

```
sudo bash create-subdomain.sh
```

Steps performed:
1. Prompts for hostname (e.g. `app.example.com`)
2. Suggests the next available port above the highest existing app port (≥8000)
3. Creates the document root with a placeholder `index.html` if it doesn't exist
4. Inserts a `Listen` directive into `ports.conf`
5. Writes and enables the VirtualHost config in `sites-available`
6. Runs `apache2ctl configtest` and restarts Apache — rolls back everything on failure
7. Optionally adds an ingress rule to a Cloudflare Tunnel config (`cloudflared config.yml`) and restarts the tunnel

---

## delete-gz-logs.sh

Deletes all `.gz` compressed log files under `/var/log/` recursively.

```
sudo bash delete-gz-logs.sh
```
