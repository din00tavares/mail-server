[English](README.md) | [Português](README.pt-BR.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [Italiano](README.it.md)

---

# Mail Server — Stalwart + Roundcube + OCI Relay

Complete guide to deploy this mail server **from scratch on another server**, with outbound sending via **OCI Email Delivery relay** (required because port 25 is blocked on OCI, both inbound and outbound).

Stack (premise: **everything on the same server**):
- **Stalwart Mail Server v0.16** (SMTP/IMAP/JMAP + webadmin) — `stalwartlabs/stalwart:latest`
- **Roundcube** (webmail) — `roundcube/roundcubemail:latest`
- **nginx-proxy-manager (NPM)** — **always present on the same host**. It acts as a reverse proxy for the webmail **and issues/renews the Let's Encrypt certificate** for `mail.<domain>`, which is **reused by Stalwart** (see [section 7](#7-default-tls-certificate-reusing-nginx-proxy-manager-cert)).
- External Docker network `proxy` (shared among the three).

> ⚠️ **Read the [Pitfalls](#9-pitfalls-that-caught-us) section before starting.** The non-obvious details make all the difference: **volume paths**, the **admin variable**, the **relay port 587**, and **TLS via NPM cert** (ports 80/443 belong to NPM, so Stalwart **cannot** use its own ACME — it reuses the NPM cert).

---

## 1. Prerequisites

1. **Server** with Docker + Docker Compose and the external `proxy` network already created:
   ```bash
   docker network create proxy   # if it doesn't exist yet
   ```
2. **nginx-proxy-manager running on the same host**, on the `proxy` network, with:
   - a **Proxy Host** for the webmail (e.g., `webmail.<domain>`) pointing to the `roundcube` container;
   - a **Proxy Host / cert** for **`mail.<domain>`** with an issued **Let's Encrypt SSL** (this is the cert Stalwart will reuse). Certs are located in `nginx-proxy-manager/letsencrypt/live/npm-<N>/`.
   > NPM occupies ports **80/443** of the host — that's why Stalwart **cannot** use its own ACME.
3. **Domain** (e.g., `example.com`) with DNS access.
4. **OCI (Oracle Cloud) Account** with the **Email Delivery** service enabled in the desired region (e.g., `sa-saopaulo-1`).
5. Open ports on the OCI firewall/Security List **for the server** (inbound):
   `25` (optional/MX inbound), `465`, `587`, `993`, `995`, `4190`, `8080` (`143` is optional).
   > **`995` (POP3S)** is required to fetch emails from **Gmail via POP3** (see `GMAIL.md`).
   > Open them both in the **OCI Security List** and the **server firewall** (iptables).
   > Outbound port **25** is blocked by OCI and **cannot** be opened — that's why we use the relay.

---

## 2. Configure OCI Email Delivery (the relay)

This is done **in the OCI console**, before touching Stalwart.

1. **Approved Senders** — `Menu → Developer Services → Email Delivery → Approved Senders`.
   Add **each address** that will send emails (e.g., `admin@example.com`, `user@example.com`, ...).
   > 🔴 If a sender is not listed here, OCI rejects the `MAIL FROM` of that address. Register all `From` addresses you intend to use.

2. **SMTP Credentials** — `Email Delivery → Configuration → SMTP Credentials → Generate`.
   Save the **username** (format `ocid1.user.oc1..aaaa...@ocid1.tenancy.oc1..aaaa....lr.com`) and the **password** (shown **only once**). These are the credentials Stalwart uses to authenticate to the relay.

3. **SMTP Endpoint** — note the host for your region, e.g.:
   `smtp.email.sa-saopaulo-1.oci.oraclecloud.com`. Port **587** (STARTTLS).

4. **DNS Authentication** (recommended to avoid spam) — in the OCI console, Email Delivery provides the **SPF** and **DKIM** records. Add them to your domain's DNS:
   - **SPF** (TXT on the domain): include the `include:` indicated by OCI.
   - **DKIM** (CNAME/TXT): generate the DKIM key in OCI and publish the records it shows.
   - **DMARC** (TXT on `_dmarc`): e.g., `v=DMARC1; p=none; rua=mailto:postmaster@your-domain`.

---

## 3. Project Files

Folder structure:

```
mail/
├── docker-compose.yml
├── .env
├── data/                 # Stalwart data (RocksDB) — persisted on host
├── etc/                  # Stalwart bootstrap config (config.json)
├── roundcube-config/     # Roundcube config.inc.php
├── roundcube-db/         # Roundcube sqlite DB
└── roundcube-plugins/    # plugins (e.g., strip_domain)
```

### 3.1 `.env`

```env
MAIL_DOMAIN=mail.your-domain.com
ADMIN_PASSWORD=a-strong-password-here
TIMEZONE=America/Sao_Paulo
```

### 3.2 `docker-compose.yml`

> ✅ **The volume paths below are the CORRECT ones for image v0.16.**
> The image uses `/var/lib/stalwart` (data) and `/etc/stalwart` (config). Mounting to `/opt/stalwart/...` (a common mistake) makes the container **not persist anything** — you lose accounts and emails on the first recreate.

```yaml
services:
  stalwart-mail:
    image: stalwartlabs/stalwart:latest
    container_name: stalwart-mail
    restart: unless-stopped
    ports:
      - "25:25"     # SMTP (MX inbound)
      - "143:143"   # Plain IMAP — OPTIONAL. You can omit this.
      - "465:465"   # SMTPS (implicit submission — used by Roundcube)
      - "587:587"   # SMTP submission (STARTTLS) — requires 'submission' listener (see 7.1)
      - "993:993"   # IMAPS
      - "995:995"   # POP3S — required to fetch Gmail via POP3 (see GMAIL.md)
      - "4190:4190" # ManageSieve
      - "8080:8080" # Webadmin / API
    volumes:
      - ./data:/var/lib/stalwart   # ← CORRECT (data/RocksDB)
      - ./etc:/etc/stalwart        # ← CORRECT (bootstrap config)
      - ./tls:/opt/tls:ro          # Let's Encrypt cert synced from NPM (see sync-cert.sh)
    environment:
      - TZ=${TIMEZONE:-America/Sao_Paulo}
      # v0.16 uses STALWART_RECOVERY_ADMIN (NOT STALWART_ADMIN_PASS, which is ignored):
      - STALWART_RECOVERY_ADMIN=admin:${ADMIN_PASSWORD}
    networks:
      - proxy

  roundcube:
    image: roundcube/roundcubemail:latest
    container_name: roundcube
    restart: unless-stopped
    environment:
      - ROUNDCUBEMAIL_DB_TYPE=sqlite
      - ROUNDCUBEMAIL_DEFAULT_HOST=ssl://stalwart-mail
      - ROUNDCUBEMAIL_DEFAULT_PORT=993
      - ROUNDCUBEMAIL_SMTP_SERVER=ssl://stalwart-mail
      - ROUNDCUBEMAIL_SMTP_PORT=465
    volumes:
      - ./roundcube-config:/var/roundcube/config
      - ./roundcube-db:/var/roundcube/db
      - ./roundcube-plugins/strip_domain:/var/www/html/plugins/strip_domain
    networks:
      - proxy

networks:
  proxy:
    external: true
```

---

## 4. First Start and Admin Access

Create the `.env` from the example and **prepare the directories with the correct owner** (Stalwart runs as uid **2000**; in a clean clone Docker would create folders as `root` and the container couldn't write):

```bash
cp .env.example .env      # and edit MAIL_DOMAIN / ADMIN_PASSWORD
mkdir -p data etc tls
sudo chown -R 2000:2000 data etc tls
docker compose up -d
docker logs -f stalwart-mail
```

On the **first** startup (empty database), Stalwart enters **bootstrap** mode and prints a temporary admin in the log:

```
🔑 Stalwart bootstrap mode - temporary administrator account
   username: admin
   password: <random-password>
```

- Access the webadmin at `http://SERVER:8080/` (or via reverse proxy).
- Since we defined `STALWART_RECOVERY_ADMIN=admin:${ADMIN_PASSWORD}`, the user **`admin`** with the password from `.env` acts as a recovery admin.
- Create the **domain** and **user accounts** (e.g., `admin@domain`, `user@domain`).

> From then on, the real admin login is usually `admin@your-domain` with the password you defined.

---

## 5. Configure the Relay in Stalwart (The Main Part)

In the webadmin, go to **Settings → SMTP → Outbound** (or the routing section) and create:

### 5.1 Outbound Route (Route → Relay Host)

| Field | Value |
|-------|-------|
| **Route type** | `Relay Host` |
| **Address** | `smtp.email.sa-saopaulo-1.oci.oraclecloud.com` (your region's endpoint) |
| **Port** | **`587`** ← essential (25 is blocked on outbound) |
| **Protocol** | `SMTP` |
| **Implicit TLS** | **Off** (587 is STARTTLS; implicit is only for 465) |
| **Allow Invalid Certs** | Off |
| **Authentication → Username** | OCI's **SMTP username** (`ocid1.user...@ocid1.tenancy....lr.com`) |
| **Authentication → Secret** | OCI's **SMTP password** |
| **Name** | `oci` (route identifier) |

### 5.2 Outbound Strategy (Outbound Strategy → Routing)

Expression that chooses the route per message — **local** delivery for your own domain and sends the rest via the `oci` relay:

```
IF   is_local_domain(rcpt_domain)
THEN 'local'
ELSE 'oci'
```

> This is what ensures "internal email stays local, external email goes via OCI".

---

## 6. Domain DNS (Summary)

| Type | Name | Value |
|------|------|-------|
| **A** | `mail.domain` | Server IP |
| **MX** | `domain` | `mail.domain` (priority 10) |
| **TXT (SPF)** | `domain` | `v=spf1 include:<OCI-include> ~all` |
| **CNAME/TXT (DKIM)** | per OCI | records provided by OCI |
| **TXT (DMARC)** | `_dmarc.domain` | `v=DMARC1; p=none; rua=mailto:postmaster@domain` |

> The exact SPF/DKIM values come from the OCI console. PTR (reverse DNS) helps with direct email delivery, but with a relay, the reputation depends on OCI.

---

## 7. TLS Certificate (Default: reusing nginx-proxy-manager cert)

**This is the default method for this setup** (not optional): since **NPM is always on the same host** and already issues/renews the Let's Encrypt cert for `mail.<domain>`, Stalwart **reuses that same cert**. Without this, Stalwart logs `No TLS certificates available (total=0)` and serves a **self-signed** cert — which generates security warnings on external email clients.

> ⚠️ We do **not** use Stalwart's own ACME here, because ports **80/443 belong to NPM** (challenge conflict). Also, the `%{file:...}%` macro only applies to local config file keys, **not** the database. That's why the cert is added as a **database object with a file reference** (`@type: File`), which works from the DB and always rereads the file (kept updated by the script + cron).

**Steps (do this always):**

1. NPM already maintains a Let's Encrypt cert for `mail.domain` in `nginx-proxy-manager/letsencrypt/live/npm-<N>/` (find `<N>` using `openssl x509 -in .../cert.pem -noout -ext subjectAltName`).
2. NPM files are `root`/`600` and Stalwart runs as **uid 2000** → it cannot read them. The [`sync-cert.sh`](sync-cert.sh) script copies `fullchain.pem`/`privkey.pem` to `./tls/` (chown 2000, chmod 640) and **restarts Stalwart only when the cert changes**.
3. Daily cron in `/etc/cron.d/stalwart-cert`:
   ```
   20 3 * * * root /home/ubuntu/apps/mail/sync-cert.sh >> /home/ubuntu/apps/mail/tls/sync.log 2>&1
   ```
4. Volume in compose: `- ./tls:/opt/tls:ro` (already included above).
5. **In the webadmin** (Settings → **TLS → Certificates → Add**): create a certificate using **file reference** (type **File**, do not paste PEM), pointing to the mounted files:
   - **Certificate / chain:** `/opt/tls/fullchain.pem`
   - **Private key:** `/opt/tls/privkey.pem`
   - Mark as **default** (sets `defaultCertificateId`).

   > Use the **File** type (`filePath`). If you paste the PEM inline, the cert in the DB becomes stale on renewal (~60-90 days). The file reference avoids this because Stalwart rereads the file (updated by cron).

**Verify:**
```bash
echo | openssl s_client -connect mail.domain:993 2>/dev/null | openssl x509 -noout -issuer -subject
# should show Let's Encrypt issuer and subject CN=mail.domain
```

### 7.1 Listener 587 (submission/STARTTLS) — create always

Stalwart only listens on ports that have a **configured listener** — even if compose publishes the port. The default installation does **not** include **`submission` (587/STARTTLS)**. Since we use 587 for external clients, **create it** in **Settings → Server → Listeners**:

- Mirror the **`submissions` (465)** listener and change: **Bind → `[::]:587`**, **Implicit TLS → off** (587 is STARTTLS). Keep **Enable TLS on**.
- Restart the container to open the new port: `docker restart stalwart-mail`.

Check which ports Stalwart actually listens to internally:
```bash
docker exec stalwart-mail sh -c 'cat /proc/net/tcp /proc/net/tcp6' \
  | awk '$4=="0A"{print $2}' | sed 's/.*://' | while read h; do printf "%d\n" "0x$h"; done | sort -nu
```

### 7.2 Preventing Nginx Proxy Manager Blocking (Error 502)

Because Stalwart has built-in brute-force protection, if it receives malicious traffic and **does not know Nginx is a trusted proxy**, it will block Nginx's internal IP (e.g., `172.18.0.x`), bringing down access with a 502 error for everyone.

To avoid this, it is **mandatory** to configure the proxy subnet in the Web Admin so Stalwart honors the `X-Forwarded-For` header and bypasses the proxy in fail2ban:

1. **Proxy Trusted Networks:** Go to **Settings → Network → General** (or Services). Under **Proxy**, find **Trusted Networks** and add the docker subnet: `172.18.0.0/16`. This makes Stalwart respect proxy headers.
2. **HTTP Forwarded Header:** Go to **Settings → Network → HTTP**. Under **Proxy**, enable **Obtain remote IP from Forwarded header**.
3. **Fail2Ban Whitelist:** Go to **Settings → Security → Allowed IPs** (or Security → Authentication → Ignored IPs). Add `172.18.0.0/16`. This grants the docker internal network absolute immunity from brute-force bans.
4. Click **Save** on all pages.

---

## 8. Sending Verification / Testing

Test **without depending on a client**, authenticating via 465 and watching the live log:

```bash
# terminal 1 — watch the log (server must have debug logging enabled)
docker logs -f stalwart-mail

# terminal 2 — send an authenticated test (change password/sender/recipient)
python3 - <<'PY'
import smtplib, ssl
from email.message import EmailMessage
ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
m = EmailMessage()
m["From"]="admin@your-domain.com"; m["To"]="you@gmail.com"
m["Subject"]="OCI Relay Test"; m.set_content("test")
s = smtplib.SMTP_SSL("127.0.0.1", 465, context=ctx, timeout=20)
s.login("admin@your-domain.com", "PASSWORD")
s.send_message(m); s.quit()
print("sent")
PY
```

In the log, success looks like:
```
Connecting to remote server ... hostname="smtp.email.sa-saopaulo-1.oci.oraclecloud.com" remotePort=587
SMTP STARTTLS command ... version="TLSv1_2"
SMTP MAIL FROM ... code=250
SMTP RCPT TO  ... code=250
Message delivered ... code=250 details="Ok"
```

Test **connectivity** from the container to the relay (use `bash`/`openssl`, **not** `sh`):
```bash
docker exec stalwart-mail bash -c \
  "echo QUIT | openssl s_client -starttls smtp -connect smtp.email.sa-saopaulo-1.oci.oraclecloud.com:587 -crlf 2>&1 | head"
```

---

## 9. Pitfalls That Caught Us

1. **Volume paths.** Image v0.16 uses `/var/lib/stalwart` and `/etc/stalwart`, **not** `/opt/stalwart/...`. If mounted incorrectly, the container runs but **does not persist** and the config appears to "disappear".
2. **Admin variable.** v0.16 uses `STALWART_RECOVERY_ADMIN=admin:<password>`. `STALWART_ADMIN_PASS` is **ignored** (the version generates a random temp password on every boot).
3. **Port 25 blocked outbound (OCI).** The relay **must** use **587** (STARTTLS). If left on 25, you get `Connection timed out (os error 110)` in the queue.
4. **Network testing with the wrong shell.** The container's `/bin/sh` is **dash**, which does **not** support `/dev/tcp`. Port tests with `sh -c '... /dev/tcp/...'` give a **false "blocked"**. Use `bash -c`, `curl`, or `openssl`.
5. **"Old" error in the queue.** After fixing the config, messages already in the queue continue showing the **last error** until the next retry. Force "Retry" in the queue or send a new email to confirm.
6. **Stalwart v0.16 config is in the database (RocksDB), not a file.** `etc/config.json` is just for bootstrap. Configuration is done via **webadmin (UI)**, JMAP, or `stalwart-cli apply`. **Configure the relay via the UI**, do not try to edit files.
7. **OCI Approved Senders.** Every `From` address must be approved in OCI, otherwise the `MAIL FROM` for that sender is rejected.

---

## 10. Backup and Restore

**Backup** (Stalwart data = accounts, emails, config, queue):
```bash
# hot backup (fast) or stop the container first for full consistency
docker exec stalwart-mail sh -c 'cd / && tar czf - var/lib/stalwart etc/stalwart' > stalwart-backup.tar.gz
```

With correct volumes, data is also in `./data` and `./etc` on the host — you can back up these folders directly (with the container stopped).

**Restore** on another server:
```bash
docker compose stop stalwart-mail
# extract the tar into ./data and ./etc (keeping the structure)
docker run --rm --user 0:0 -v "$PWD/data:/d" -v "$PWD/etc:/e" alpine chown -R 2000:2000 /d /e
docker compose up -d stalwart-mail
```
> The Stalwart process runs as **uid 2000** — hence the `chown -R 2000:2000` on the data.

---

## Quick Reference

| Item | Value |
|------|-------|
| Image | `stalwartlabs/stalwart:latest` (v0.16) |
| Data (in container) | `/var/lib/stalwart` (RocksDB) |
| Bootstrap config | `/etc/stalwart/config.json` |
| Process UID | `2000:2000` |
| Webadmin | port `8080` |
| OCI Relay | `smtp.email.<region>.oci.oraclecloud.com:587` (STARTTLS + AUTH) |
| Recovery Admin | `STALWART_RECOVERY_ADMIN=admin:<password>` |
| TLS | LE cert from **NPM** (`mail.<domain>`), mounted at `/opt/tls` via `sync-cert.sh` + cron; Certificate object in webadmin with `@type File` |
| Ports in use | `25, 465, 587, 993, 995, 4190, 8080` (587 manually created; 995 for Gmail POP3S; `143` not used) |
| NPM Ports | `80/443` (Stalwart does not use its own ACME) |
