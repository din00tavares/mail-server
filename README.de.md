[English](README.md) | [Português](README.pt-BR.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [Italiano](README.it.md)

---

# Mailserver — Stalwart + Roundcube + OCI Relay

Komplette Anleitung zum Aufsetzen dieses Mailservers **von Grund auf auf einem anderen Server**, mit ausgehendem Versand über das **OCI Email Delivery Relay** (erforderlich, da Port 25 bei OCI sowohl eingehend als auch ausgehend blockiert ist).

Stack (Voraussetzung: **alles auf demselben Server**):
- **Stalwart Mail Server v0.16** (SMTP/IMAP/JMAP + Webadmin) — `stalwartlabs/stalwart:latest`
- **Roundcube** (Webmail) — `roundcube/roundcubemail:latest`
- **nginx-proxy-manager (NPM)** — **immer auf demselben Host vorhanden**. Fungiert als Reverse-Proxy für das Webmail **und stellt/erneuert das Let's Encrypt-Zertifikat** für `mail.<domain>`, das **von Stalwart wiederverwendet wird** (siehe [Abschnitt 7](#7-tls-zertifikat-wiederverwendung-des-nginx-proxy-manager-zertifikats)).
- Externes Docker-Netzwerk `proxy` (wird von allen dreien geteilt).

> ⚠️ **Lesen Sie den Abschnitt [Stolpersteine](#9-stolpersteine-die-uns-erwischt-haben), bevor Sie beginnen.** Die nicht offensichtlichen Details machen den Unterschied: die **Volume-Pfade**, die **Admin-Variable**, der **Relay-Port 587** und **TLS über das NPM-Zertifikat** (Ports 80/443 gehören NPM, weshalb Stalwart **nicht** sein eigenes ACME verwenden kann).

---

## 1. Voraussetzungen

1. **Server** mit Docker + Docker Compose und dem bereits erstellten externen Netzwerk `proxy`:
   ```bash
   docker network create proxy   # falls noch nicht vorhanden
   ```
2. **nginx-proxy-manager läuft auf demselben Host**, im Netzwerk `proxy`, mit:
   - einem **Proxy Host** für das Webmail (z. B. `webmail.<domain>`), der auf den Container `roundcube` verweist;
   - einem **Proxy Host / Zertifikat** für **`mail.<domain>`** mit einem ausgestellten **Let's Encrypt SSL** (dies ist das Zertifikat, das Stalwart wiederverwenden wird).
3. **Domain** (z. B. `beispiel.de`) mit DNS-Zugang.
4. **OCI (Oracle Cloud) Konto** mit aktiviertem **Email Delivery**-Dienst in der gewünschten Region.
5. Geöffnete Ports in der OCI Firewall/Security List **für den Server** (eingehend):
   `25` (optional), `465`, `587`, `993`, `995`, `4190`, `8080`.
   > Der **ausgehende Port 25** wird von OCI blockiert und kann **nicht** geöffnet werden — deshalb verwenden wir das Relay.

---

## 2. OCI Email Delivery konfigurieren (das Relay)

Dies geschieht **in der OCI-Konsole**, bevor Sie Stalwart anrühren.

1. **Approved Senders**. Fügen Sie **jede Adresse** hinzu, die E-Mails senden wird.
2. **SMTP Credentials**. Speichern Sie den **Benutzernamen** und das **Passwort** (wird nur einmal angezeigt).
3. **SMTP-Endpunkt** — notieren Sie sich den Host Ihrer Region. Port **587**.
4. **DNS-Authentifizierung** — Fügen Sie die von OCI bereitgestellten **SPF**- und **DKIM**-Einträge zum DNS Ihrer Domain hinzu.

---

## 3. Projektdateien

Ordnerstruktur:

```
mail/
├── docker-compose.yml
├── .env
├── data/                 # Stalwart-Daten (RocksDB)
├── etc/                  # Stalwart Bootstrap-Konfig
├── roundcube-config/
├── roundcube-db/
└── roundcube-plugins/
```

### 3.1 `.env`

```env
MAIL_DOMAIN=mail.deine-domain.de
ADMIN_PASSWORD=ein-starkes-passwort-hier
TIMEZONE=Europe/Berlin
```

### 3.2 `docker-compose.yml`

> ✅ **Die Volume-Pfade unten sind die RICHTIGEN für das Image v0.16.**

```yaml
services:
  stalwart-mail:
    image: stalwartlabs/stalwart:latest
    container_name: stalwart-mail
    restart: unless-stopped
    ports:
      - "25:25"
      - "465:465"
      - "587:587"
      - "993:993"
      - "995:995"
      - "4190:4190"
      - "8080:8080"
    volumes:
      - ./data:/var/lib/stalwart   # ← KORREKT (Daten/RocksDB)
      - ./etc:/etc/stalwart        # ← KORREKT (Bootstrap-Konfig)
      - ./tls:/opt/tls:ro          # Let's Encrypt Zertifikat von NPM
    environment:
      - TZ=${TIMEZONE:-Europe/Berlin}
      - STALWART_RECOVERY_ADMIN=admin:${ADMIN_PASSWORD}
    networks:
      - proxy

  roundcube:
    image: roundcube/roundcubemail:latest
    # ... Rest der Roundcube-Konfiguration ...
```

---

## 4. Erster Start und Admin-Zugang

Erstellen Sie die `.env` und bereiten Sie die Verzeichnisse vor (Stalwart läuft als UID **2000**):

```bash
cp .env.example .env
mkdir -p data etc tls
sudo chown -R 2000:2000 data etc tls
docker compose up -d
```

Greifen Sie auf den Webadmin unter `http://SERVER:8080/` zu. Der Benutzer **`admin`** mit dem Passwort aus `.env` fungiert als Wiederherstellungs-Admin.

---

## 5. Das Relay in Stalwart konfigurieren

Gehen Sie im Webadmin zu **Settings → SMTP → Outbound** und erstellen Sie:

### 5.1 Ausgehende Route (Route → Relay Host)
Setzen Sie Port **587** (STARTTLS) und geben Sie Ihre OCI-Anmeldeinformationen ein.

### 5.2 Ausgehende Strategie (Outbound Strategy → Routing)
```
IF   is_local_domain(rcpt_domain)
THEN 'local'
ELSE 'oci'
```

---

## 7. TLS-Zertifikat (Wiederverwendung des nginx-proxy-manager Zertifikats)

Stalwart verwendet das Let's Encrypt Zertifikat von NPM wieder.
Das Skript `sync-cert.sh` kopiert die Zertifikate nach `./tls/`.

### 7.1 Listener 587 erstellen
Stalwart bringt standardmäßig keinen `submission` (587/STARTTLS) Listener mit. Erstellen Sie ihn unter **Settings → Server → Listeners**.

### 7.2 Blockierung des Nginx Proxy Managers verhindern (Fehler 502)
Damit die Brute-Force-Protection von Stalwart nicht den NPM blockiert, muss das Proxy-Netzwerk zwingend konfiguriert werden:
1. **Proxy Trusted Networks:** Gehen Sie zu **Settings → Network → General** (oder Services). Unter **Proxy** fügen Sie das Docker-Subnetz zu **Trusted Networks** hinzu: `172.18.0.0/16`.
2. **HTTP Forwarded Header:** Gehen Sie zu **Settings → Network → HTTP**. Aktivieren Sie unter **Proxy** die Option **Obtain remote IP from Forwarded header**.
3. **Fail2Ban Whitelist:** Gehen Sie zu **Settings → Security → Allowed IPs** (oder Security → Authentication → Ignored IPs) und fügen Sie `172.18.0.0/16` hinzu. Dies schützt das interne Netzwerk vor Blockaden.
4. Klicken Sie überall auf **Save**.

---

## 9. Stolpersteine

1. **Volume-Pfade.** v0.16 verwendet `/var/lib/stalwart`, **nicht** `/opt/stalwart/...`.
2. **Admin-Variable.** Verwenden Sie `STALWART_RECOVERY_ADMIN`, nicht `STALWART_ADMIN_PASS`.
3. **Konfiguration erfolgt über die UI.** Bearbeiten Sie nicht die config.json nach dem Bootstrap.
