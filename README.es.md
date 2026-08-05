[English](README.md) | [Português](README.pt-BR.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [Italiano](README.it.md)

---

# Servidor de Correo — Stalwart + Roundcube + Relay OCI

Guía completa para implementar este servidor de correo **desde cero en otro servidor**, con envío de salida a través del **relay de OCI Email Delivery** (necesario porque el puerto 25 está bloqueado en OCI, tanto de entrada como de salida).

Stack (premisa: **todo en el mismo servidor**):
- **Stalwart Mail Server v0.16** (SMTP/IMAP/JMAP + webadmin) — `stalwartlabs/stalwart:latest`
- **Roundcube** (webmail) — `roundcube/roundcubemail:latest`
- **nginx-proxy-manager (NPM)** — **siempre presente en el mismo host**. Actúa como proxy inverso para el webmail **y emite/renueva el certificado Let's Encrypt** para `mail.<dominio>`, que es **reutilizado por Stalwart** (ver [sección 7](#7-certificado-tls-predeterminado-reutilizando-el-cert-de-nginx-proxy-manager)).
- Red Docker externa `proxy` (compartida entre los tres).

> ⚠️ **Lea la sección [Trampas](#9-trampas-que-nos-atraparon) antes de comenzar.** Los detalles no obvios hacen toda la diferencia: las **rutas de los volúmenes**, la **variable de admin**, el **puerto 587 del relay**, y el **TLS vía certificado de NPM** (los puertos 80/443 son de NPM, por lo que Stalwart **no puede** usar su propio ACME — reutiliza el de NPM).

---

## 1. Requisitos previos

1. **Servidor** con Docker + Docker Compose y la red externa `proxy` ya creada:
   ```bash
   docker network create proxy   # si aún no existe
   ```
2. **nginx-proxy-manager corriendo en el mismo host**, en la red `proxy`, con:
   - un **Proxy Host** para el webmail (ej.: `webmail.<dominio>`) apuntando al contenedor `roundcube`;
   - un **Proxy Host / cert** para **`mail.<dominio>`** con **SSL Let's Encrypt** emitido (este es el cert que Stalwart reutilizará). Los certificados están en `nginx-proxy-manager/letsencrypt/live/npm-<N>/`.
   > NPM ocupa los puertos **80/443** del host — por eso Stalwart **no** puede usar ACME propio.
3. **Dominio** (ej.: `ejemplo.com`) con acceso al DNS.
4. **Cuenta OCI (Oracle Cloud)** con el servicio **Email Delivery** habilitado en la región deseada (ej.: `sa-saopaulo-1`).
5. Puertos abiertos en el firewall/Security List de OCI **para el servidor** (entrada):
   `25` (opcional/entrada de MX), `465`, `587`, `993`, `995`, `4190`, `8080` (`143` es opcional).
   > El puerto **`995` (POP3S)** es necesario para buscar correos de **Gmail vía POP3** (ver `GMAIL.md`).
   > Ábralos tanto en la **Security List de OCI** como en el **firewall del servidor** (iptables).
   > El puerto **25 de salida** está bloqueado por OCI y **no** se puede abrir — por eso usamos el relay.

---

## 2. Configurar OCI Email Delivery (el relay)

Esto se hace **en la consola de OCI**, antes de tocar Stalwart.

1. **Approved Senders** — `Menu → Developer Services → Email Delivery → Approved Senders`.
   Agregue **cada dirección** que enviará correos (ej.: `admin@ejemplo.com`, `usuario@ejemplo.com`, ...).
   > 🔴 Si un remitente no está aquí, OCI rechaza el `MAIL FROM` de esa dirección. Registre todos los `From` que pretende usar.

2. **SMTP Credentials** — `Email Delivery → Configuration → SMTP Credentials → Generate`.
   Guarde el **username** (formato `ocid1.user.oc1..aaaa...@ocid1.tenancy.oc1..aaaa....lr.com`) y el **password** (mostrado **una sola vez**). Estas son las credenciales que Stalwart usa para autenticarse en el relay.

3. **Endpoint SMTP** — anote el host de su región, ej.:
   `smtp.email.sa-saopaulo-1.oci.oraclecloud.com`. Puerto **587** (STARTTLS).

4. **DNS de autenticación** (recomendado para no caer en spam) — en la consola de OCI, Email Delivery proporciona los registros de **SPF** y **DKIM**. Agréguelos al DNS de su dominio:
   - **SPF** (TXT en el dominio): incluya el `include:` indicado por OCI.
   - **DKIM** (CNAME/TXT): genere la clave DKIM en OCI y publique los registros que muestre.
   - **DMARC** (TXT en `_dmarc`): ej., `v=DMARC1; p=none; rua=mailto:postmaster@su-dominio`.

---

## 3. Archivos del proyecto

Estructura de la carpeta:

```
mail/
├── docker-compose.yml
├── .env
├── data/                 # datos de Stalwart (RocksDB) — persistido en el host
├── etc/                  # config bootstrap de Stalwart (config.json)
├── roundcube-config/     # config.inc.php de Roundcube
├── roundcube-db/         # sqlite de Roundcube
└── roundcube-plugins/    # plugins (ej.: strip_domain)
```

### 3.1 `.env`

```env
MAIL_DOMAIN=mail.su-dominio.com
ADMIN_PASSWORD=una-contraseña-fuerte-aqui
TIMEZONE=America/Sao_Paulo
```

### 3.2 `docker-compose.yml`

> ✅ **Las rutas de los volúmenes abajo son las CORRECTAS para la imagen v0.16.**
> La imagen usa `/var/lib/stalwart` (datos) y `/etc/stalwart` (config). Montar en `/opt/stalwart/...` (error común) hace que el contenedor **no persista nada** — perderá cuentas y correos al recrear.

```yaml
services:
  stalwart-mail:
    image: stalwartlabs/stalwart:latest
    container_name: stalwart-mail
    restart: unless-stopped
    ports:
      - "25:25"     # SMTP (entrada MX)
      - "143:143"   # IMAP plano — OPCIONAL.
      - "465:465"   # SMTPS (sumisión implícita — usada por Roundcube)
      - "587:587"   # SMTP submission (STARTTLS) — requiere el listener 'submission' (ver 7.1)
      - "993:993"   # IMAPS
      - "995:995"   # POP3S — necesario para Gmail vía POP3 (ver GMAIL.md)
      - "4190:4190" # ManageSieve
      - "8080:8080" # Webadmin / API
    volumes:
      - ./data:/var/lib/stalwart   # ← CORRECTO (datos/RocksDB)
      - ./etc:/etc/stalwart        # ← CORRECTO (config bootstrap)
      - ./tls:/opt/tls:ro          # cert Let's Encrypt sincronizado de NPM
    environment:
      - TZ=${TIMEZONE:-America/Sao_Paulo}
      # v0.16 usa STALWART_RECOVERY_ADMIN (NO STALWART_ADMIN_PASS):
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

## 4. Primer inicio y acceso como administrador

Cree el `.env` a partir del ejemplo y **prepare los directorios con el propietario correcto** (Stalwart se ejecuta como uid **2000**; en un clon limpio, Docker los crearía como `root` y fallaría):

```bash
cp .env.example .env      # edite MAIL_DOMAIN / ADMIN_PASSWORD
mkdir -p data etc tls
sudo chown -R 2000:2000 data etc tls
docker compose up -d
docker logs -f stalwart-mail
```

En el **primer** inicio (base de datos vacía), Stalwart entra en **bootstrap** y muestra un admin temporal:

```
🔑 Stalwart bootstrap mode - temporary administrator account
   username: admin
   password: <contraseña-aleatoria>
```

- Acceda al webadmin en `http://SERVIDOR:8080/` (o por el proxy inverso).
- Como definimos `STALWART_RECOVERY_ADMIN=admin:${ADMIN_PASSWORD}`, el usuario **`admin`** con la contraseña del `.env` funciona como admin de recuperación.
- Cree el **dominio** y las **cuentas** de usuario.

---

## 5. Configurar el relay en Stalwart (La parte principal)

En el webadmin, vaya a **Settings → SMTP → Outbound** (o la sección de rutas) y cree:

### 5.1 Ruta de salida (Route → Relay Host)

| Campo | Valor |
|-------|-------|
| **Route type** | `Relay Host` |
| **Address** | `smtp.email.sa-saopaulo-1.oci.oraclecloud.com` (endpoint de su región) |
| **Port** | **`587`** ← esencial |
| **Protocol** | `SMTP` |
| **Implicit TLS** | **Apagado** |
| **Allow Invalid Certs** | Apagado |
| **Authentication → Username** | El **SMTP username** de OCI |
| **Authentication → Secret** | El **SMTP password** de OCI |
| **Name** | `oci` (identificador) |

### 5.2 Estrategia de salida (Outbound Strategy → Routing)

```
IF   is_local_domain(rcpt_domain)
THEN 'local'
ELSE 'oci'
```

> Esto garantiza que "el correo interno se queda local y el externo va por OCI".

---

## 6. DNS del dominio (Resumen)

| Tipo | Nombre | Valor |
|------|------|-------|
| **A** | `mail.dominio` | IP del servidor |
| **MX** | `dominio` | `mail.dominio` (prioridad 10) |
| **TXT (SPF)** | `dominio` | `v=spf1 include:<include-de-OCI> ~all` |
| **CNAME/TXT (DKIM)** | según OCI | registros de OCI |
| **TXT (DMARC)** | `_dmarc.dominio` | `v=DMARC1; p=none; rua=mailto:postmaster@dominio` |

---

## 7. Certificado TLS (Reutilizando el cert de nginx-proxy-manager)

**Este es el método predeterminado** (no opcional): como **NPM siempre está en el mismo host** y ya gestiona Let's Encrypt para `mail.<dominio>`, Stalwart **reutiliza el mismo certificado**.

> ⚠️ **No** se usa el ACME propio de Stalwart porque los puertos **80/443 son de NPM**. El certificado entra como **objeto en la base de datos con referencia a archivo** (`@type: File`).

**Pasos:**

1. El script [`sync-cert.sh`](sync-cert.sh) copia `fullchain.pem`/`privkey.pem` a `./tls/` (chown 2000, chmod 640) y **reinicia Stalwart si el certificado cambia**.
2. Cron diario en `/etc/cron.d/stalwart-cert`:
   ```
   20 3 * * * root /home/ubuntu/apps/mail/sync-cert.sh >> /home/ubuntu/apps/mail/tls/sync.log 2>&1
   ```
3. Volumen en compose: `- ./tls:/opt/tls:ro`.
4. **En el webadmin** (Settings → **TLS → Certificates → Add**): cree un certificado usando **referencia a archivo** (tipo **File**):
   - **Certificate / chain:** `/opt/tls/fullchain.pem`
   - **Private key:** `/opt/tls/privkey.pem`
   - Marcar como **default**.

### 7.1 Listener 587 (submission/STARTTLS) — crear siempre

Stalwart no trae **`submission` (587/STARTTLS)** por defecto. **Créelo** en **Settings → Server → Listeners**:
- Duplique el listener **`submissions` (465)** y cambie: **Bind → `[::]:587`**, **Implicit TLS → apagado**.
- Reinicie el contenedor.

### 7.2 Evitar bloqueo de Nginx Proxy Manager (Error 502)

Como Stalwart tiene protección contra ataques de fuerza bruta, si recibe tráfico malicioso y **no sabe que Nginx es un proxy confiable**, bloqueará la IP interna de Nginx (ej.: `172.18.0.x`), causando un error 502 para todos.

Para evitar esto, es **obligatorio** configurar la red del proxy en el panel web para que Stalwart respete el IP real y no bloquee al proxy:

1. **Proxy Trusted Networks:** Vaya a **Settings → Network → General** (o Services). En la sección **Proxy**, busque **Trusted Networks** y agregue la subred de Docker: `172.18.0.0/16`.
2. **HTTP Forwarded Header:** Vaya a **Settings → Network → HTTP**. En la sección **Proxy**, active **Obtain remote IP from Forwarded header**.
3. **Fail2Ban Whitelist:** Vaya a **Settings → Security → Allowed IPs** (o Security → Authentication → Ignored IPs). Agregue `172.18.0.0/16`. Esto da inmunidad absoluta a la red interna contra bloqueos.
4. Haga clic en **Save** en todas las pantallas.

---

## 8. Verificación / prueba de envío

```bash
# terminal 1
docker logs -f stalwart-mail

# terminal 2
python3 - <<'PY'
import smtplib, ssl
from email.message import EmailMessage
ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
m = EmailMessage()
m["From"]="admin@su-dominio.com"; m["To"]="tu@gmail.com"
m["Subject"]="Prueba OCI"; m.set_content("test")
s = smtplib.SMTP_SSL("127.0.0.1", 465, context=ctx, timeout=20)
s.login("admin@su-dominio.com", "CONTRASEÑA")
s.send_message(m); s.quit()
print("enviado")
PY
```

---

## 9. Trampas que nos atraparon

1. **Rutas de volúmenes.** v0.16 usa `/var/lib/stalwart`, **no** `/opt/stalwart/...`.
2. **Variable de admin.** `STALWART_RECOVERY_ADMIN=admin:<contraseña>`.
3. **Puerto 25 bloqueado (OCI).** El relay **debe** usar **587**.
4. **Shell incorrecto.** `/bin/sh` en el contenedor es **dash** (no soporta `/dev/tcp`).
5. **Error "antiguo" en la cola.** Fuerce el reintento de la cola o envíe un nuevo correo.
6. **Configuración en RocksDB.** Configúrelo todo por la UI web, no edite el archivo.
7. **Approved Senders en OCI.** Cada `From` debe estar aprobado.

---

## 10. Backup y restauración

**Backup:**
```bash
docker exec stalwart-mail sh -c 'cd / && tar czf - var/lib/stalwart etc/stalwart' > stalwart-backup.tar.gz
```

**Restaurar:**
```bash
docker compose stop stalwart-mail
docker run --rm --user 0:0 -v "$PWD/data:/d" -v "$PWD/etc:/e" alpine chown -R 2000:2000 /d /e
docker compose up -d stalwart-mail
```
