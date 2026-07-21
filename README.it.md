[English](README.md) | [Português](README.pt-BR.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [Italiano](README.it.md)

---

# Server di Posta — Stalwart + Roundcube + Relay OCI

Guida completa per configurare questo server di posta **da zero su un altro server**, con invio in uscita tramite il **relay di OCI Email Delivery** (necessario perché la porta 25 è bloccata su OCI, sia in entrata che in uscita).

Stack (premessa: **tutto sullo stesso server**):
- **Stalwart Mail Server v0.16** (SMTP/IMAP/JMAP + webadmin) — `stalwartlabs/stalwart:latest`
- **Roundcube** (webmail) — `roundcube/roundcubemail:latest`
- **nginx-proxy-manager (NPM)** — **sempre presente sullo stesso host**. Funge da reverse proxy per la webmail **ed emette/rinnova il certificato Let's Encrypt** per `mail.<dominio>`, che viene **riutilizzato da Stalwart** (vedi [sezione 7](#7-certificato-tls-predefinito-riutilizzo-del-certificato-di-nginx-proxy-manager)).
- Rete Docker esterna `proxy` (condivisa tra i tre).

> ⚠️ **Leggi la sezione [Insidie](#9-insidie-che-ci-hanno-colpito) prima di iniziare.** I dettagli non ovvi fanno la differenza: i **percorsi dei volumi**, la **variabile admin**, la **porta 587 del relay** e il **TLS tramite certificato NPM** (le porte 80/443 appartengono a NPM, quindi Stalwart **non** può usare il proprio ACME).

---

## 1. Prerequisiti

1. **Server** con Docker + Docker Compose e la rete esterna `proxy` già creata.
2. **nginx-proxy-manager in esecuzione sullo stesso host**, nella rete `proxy`.
3. **Dominio** (es.: `esempio.it`) con accesso DNS.
4. **Account OCI (Oracle Cloud)** con il servizio **Email Delivery** abilitato.
5. Porte aperte nel firewall/Security List di OCI **per il server** (in entrata):
   `25` (opzionale), `465`, `587`, `993`, `995`, `4190`, `8080`.

---

## 2. Configurare OCI Email Delivery (il relay)

Questo viene fatto **nella console OCI**, prima di toccare Stalwart.

1. **Approved Senders**. Aggiungi **ogni indirizzo** che invierà e-mail.
2. **SMTP Credentials**. Salva l'**username** e la **password** (mostrata solo una volta).
3. **Endpoint SMTP** — annota l'host della tua regione. Porta **587**.
4. **Autenticazione DNS** — Aggiungi i record **SPF** e **DKIM** forniti da OCI al DNS del tuo dominio.

---

## 3. File del progetto

Struttura della cartella:

```
mail/
├── docker-compose.yml
├── .env
├── data/                 # dati Stalwart (RocksDB)
├── etc/                  # configurazione bootstrap Stalwart
├── roundcube-config/
├── roundcube-db/
└── roundcube-plugins/
```

### 3.1 `.env`

```env
MAIL_DOMAIN=mail.tuo-dominio.it
ADMIN_PASSWORD=una-password-forte-qui
TIMEZONE=Europe/Rome
```

### 3.2 `docker-compose.yml`

> ✅ **I percorsi dei volumi sottostanti sono quelli CORRETTI per l'immagine v0.16.**

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
      - ./data:/var/lib/stalwart   # ← CORRETTO (dati/RocksDB)
      - ./etc:/etc/stalwart        # ← CORRETTO (config bootstrap)
      - ./tls:/opt/tls:ro          # certificato Let's Encrypt di NPM
    environment:
      - TZ=${TIMEZONE:-Europe/Rome}
      - STALWART_RECOVERY_ADMIN=admin:${ADMIN_PASSWORD}
    networks:
      - proxy

  roundcube:
    image: roundcube/roundcubemail:latest
    # ... resto della configurazione di Roundcube ...
```

---

## 4. Primo avvio e accesso amministratore

Crea il file `.env` e prepara le directory (Stalwart viene eseguito come uid **2000**):

```bash
cp .env.example .env
mkdir -p data etc tls
sudo chown -R 2000:2000 data etc tls
docker compose up -d
```

Accedi alla webadmin su `http://SERVER:8080/`. L'utente **`admin`** con la password del `.env` funziona come amministratore di ripristino.

---

## 5. Configurare il relay in Stalwart

Nella webadmin, vai su **Settings → SMTP → Outbound** e crea:

### 5.1 Rotta in uscita (Route → Relay Host)
Imposta la porta **587** (STARTTLS) e inserisci le tue credenziali OCI.

### 5.2 Strategia in uscita (Outbound Strategy → Routing)
```
IF   is_local_domain(rcpt_domain)
THEN 'local'
ELSE 'oci'
```

---

## 7. Certificato TLS (Riutilizzo del certificato di nginx-proxy-manager)

Stalwart riutilizza il certificato Let's Encrypt di NPM.
Lo script `sync-cert.sh` copia i certificati in `./tls/`.

### 7.1 Creare Listener 587
L'installazione predefinita non include un listener per `submission` (587/STARTTLS). Crealo in **Settings → Server → Listeners**.

### 7.2 Prevenire il blocco di Nginx Proxy Manager (Errore 502)
Affinché la protezione brute-force di Stalwart non blocchi NPM:
1. Vai su **Settings → Network → HTTP**.
2. Abilita **Obtain remote IP from Forwarded header**.

---

## 9. Insidie che ci hanno colpito

1. **Percorsi dei volumi.** La v0.16 usa `/var/lib/stalwart`, **non** `/opt/stalwart/...`.
2. **Variabile admin.** Usa `STALWART_RECOVERY_ADMIN`, non `STALWART_ADMIN_PASS`.
3. **La configurazione avviene tramite UI.** Non modificare il file config.json dopo il bootstrap.
