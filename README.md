# Servidor de E-mail — Stalwart + Roundcube + Relay OCI

Guia completo para subir este servidor de e-mail **do zero em outro servidor**, com envio de saída
via **relay do OCI Email Delivery** (necessário porque a porta 25 é bloqueada na OCI, tanto de
entrada quanto de saída).

Stack (premissa: **tudo no mesmo servidor**):
- **Stalwart Mail Server v0.16** (SMTP/IMAP/JMAP + webadmin) — `stalwartlabs/stalwart:latest`
- **Roundcube** (webmail) — `roundcube/roundcubemail:latest`
- **nginx-proxy-manager (NPM)** — **sempre presente no mesmo host**. Faz o proxy reverso do webmail
  **e emite/renova o certificado Let's Encrypt** de `mail.<domínio>`, que é **reaproveitado pelo
  Stalwart** (ver [seção 7](#7-certificado-tls-padrão-reaproveitando-o-cert-do-nginx-proxy-manager)).
- Rede Docker externa `proxy` (compartilhada entre os três).

> ⚠️ **Leia a seção [Armadilhas](#armadilhas-que-já-nos-pegaram) antes de começar.** Os detalhes
> não óbvios que fazem toda a diferença: os **caminhos dos volumes**, a **variável de admin**, a
> **porta 587 do relay**, e o **TLS via cert do NPM** (as portas 80/443 são do NPM, então o Stalwart
> **não** usa ACME próprio — reaproveita o cert do NPM).

---

## 1. Pré-requisitos

1. **Servidor** com Docker + Docker Compose e a rede externa `proxy` já criada:
   ```bash
   docker network create proxy   # se ainda não existir
   ```
2. **nginx-proxy-manager rodando no mesmo host**, na rede `proxy`, com:
   - um **Proxy Host** para o webmail (ex.: `webmail.<domínio>`) apontando para o container `roundcube`;
   - um **Proxy Host / cert** para **`mail.<domínio>`** com **SSL Let's Encrypt** emitido (é esse
     cert que o Stalwart vai reaproveitar). Os certs ficam em
     `nginx-proxy-manager/letsencrypt/live/npm-<N>/`.
   > O NPM ocupa as portas **80/443** do host — por isso o Stalwart **não** pode usar ACME próprio.
3. **Domínio** (ex.: `exemplo.com.br`) com acesso ao DNS.
4. **Conta OCI (Oracle Cloud)** com o serviço **Email Delivery** habilitado na região desejada
   (ex.: `sa-saopaulo-1`).
5. Portas liberadas no firewall/Security List da OCI **para o servidor** (entrada):
   `25` (opcional/entrada de MX), `465`, `587`, `993`, `995`, `4190`, `8080` (a `143` é dispensável).
   > A **`995` (POP3S)** é necessária para buscar e-mails pelo **Gmail via POP3** (ver `GMAIL.md`).
   > Abra tanto na **Security List da OCI** quanto no **firewall do servidor** (iptables).
   > A porta **25 de saída** é bloqueada pela OCI e **não** tem como abrir — por isso usamos o relay.

---

## 2. Configurar o OCI Email Delivery (o relay)

Isto é feito **no console da OCI**, antes de mexer no Stalwart.

1. **Approved Senders** — `Menu → Developer Services → Email Delivery → Approved Senders`.
   Adicione **cada endereço** que vai enviar e-mail (ex.: `admin@exemplo.com.br`,
   `usuario@exemplo.com.br`, ...).
   > 🔴 Se um remetente não estiver aqui, a OCI recusa o `MAIL FROM` daquele endereço.
   > Cadastre todos os `From` que você pretende usar.

2. **SMTP Credentials** — `Email Delivery → Configuration → SMTP Credentials → Generate`.
   Guarde o **username** (formato `ocid1.user.oc1..aaaa...@ocid1.tenancy.oc1..aaaa....lr.com`)
   e o **password** (mostrado **uma única vez**). São essas credenciais que o Stalwart usa para
   autenticar no relay.

3. **Endpoint SMTP** — anote o host da sua região, ex.:
   `smtp.email.sa-saopaulo-1.oci.oraclecloud.com`. Porta **587** (STARTTLS).

4. **DNS de autenticação** (recomendado para não cair em spam) — no console da OCI o Email Delivery
   fornece os registros de **SPF** e **DKIM**. Adicione-os no DNS do domínio:
   - **SPF** (TXT no domínio): inclua o `include:` que a OCI indicar.
   - **DKIM** (CNAME/TXT): gere a chave DKIM na OCI e publique os registros que ela mostrar.
   - **DMARC** (TXT em `_dmarc`): ex. `v=DMARC1; p=none; rua=mailto:postmaster@seu-dominio`.

---

## 3. Arquivos do projeto

Estrutura da pasta:

```
mail/
├── docker-compose.yml
├── .env
├── data/                 # dados do Stalwart (RocksDB) — persistido no host
├── etc/                  # config bootstrap do Stalwart (config.json)
├── roundcube-config/     # config.inc.php do Roundcube
├── roundcube-db/         # sqlite do Roundcube
└── roundcube-plugins/    # plugins (ex.: strip_domain)
```

### 3.1 `.env`

```env
MAIL_DOMAIN=mail.seu-dominio.com.br
ADMIN_PASSWORD=uma-senha-forte-aqui
TIMEZONE=America/Sao_Paulo
```

### 3.2 `docker-compose.yml`

> ✅ **Os caminhos dos volumes abaixo são os CORRETOS para a imagem v0.16.**
> A imagem usa `/var/lib/stalwart` (dados) e `/etc/stalwart` (config). Montar em `/opt/stalwart/...`
> (erro comum, e o que estava errado aqui antes) faz o container **não persistir nada** — você perde
> contas e e-mails no primeiro recreate.

```yaml
services:
  stalwart-mail:
    image: stalwartlabs/stalwart:latest
    container_name: stalwart-mail
    restart: unless-stopped
    ports:
      - "25:25"     # SMTP (entrada de MX)
      - "143:143"   # IMAP plano — OPCIONAL (não usamos; só IMAPS/993). Pode omitir.
      - "465:465"   # SMTPS (submissão implícita — usada pelo Roundcube)
      - "587:587"   # SMTP submission (STARTTLS) — requer o listener 'submission' (ver 7.1)
      - "993:993"   # IMAPS
      - "995:995"   # POP3S — necessária p/ buscar e-mails pelo Gmail via POP3 (ver GMAIL.md)
      - "4190:4190" # ManageSieve
      - "8080:8080" # Webadmin / API
    volumes:
      - ./data:/var/lib/stalwart   # ← CORRETO (dados/RocksDB)
      - ./etc:/etc/stalwart        # ← CORRETO (config bootstrap)
    environment:
      - TZ=${TIMEZONE:-America/Sao_Paulo}
      # v0.16 usa STALWART_RECOVERY_ADMIN (NÃO STALWART_ADMIN_PASS, que é ignorado):
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

## 4. Primeira subida e acesso ao admin

Crie o `.env` a partir do exemplo e **prepare os diretórios com o dono correto** (o Stalwart roda
como uid **2000**; num clone limpo o Docker criaria as pastas como `root` e o container não
conseguiria escrever):

```bash
cp .env.example .env      # e edite MAIL_DOMAIN / ADMIN_PASSWORD
mkdir -p data etc tls
sudo chown -R 2000:2000 data etc tls
docker compose up -d
docker logs -f stalwart-mail
```

Na **primeira** subida (banco vazio) o Stalwart entra em **bootstrap** e mostra no log um admin
temporário:

```
🔑 Stalwart bootstrap mode - temporary administrator account
   username: admin
   password: <senha-aleatória>
```

- Acesse o webadmin em `http://SERVIDOR:8080/` (ou pelo proxy reverso).
- Como definimos `STALWART_RECOVERY_ADMIN=admin:${ADMIN_PASSWORD}`, o usuário **`admin`** com a
  senha do `.env` funciona como admin de recuperação.
- Crie o **domínio** e as **contas** de usuário (ex.: `admin@dominio`, `usuario@dominio`).

> A partir daí, o login de admin real costuma ser `admin@seu-dominio` com a senha que você definiu.

---

## 5. Configurar o relay no Stalwart (a parte principal)

No webadmin, vá em **Settings → SMTP → Outbound** (ou a seção de rotas/routing) e crie:

### 5.1 Rota de saída (Route → Relay Host)

| Campo | Valor |
|-------|-------|
| **Route type** | `Relay Host` |
| **Address** | `smtp.email.sa-saopaulo-1.oci.oraclecloud.com` (o endpoint da sua região) |
| **Port** | **`587`** ← essencial (a 25 é bloqueada na saída) |
| **Protocol** | `SMTP` |
| **Implicit TLS** | **Desligado** (na 587 é STARTTLS; implícito só serve pra 465) |
| **Allow Invalid Certs** | Desligado |
| **Authentication → Username** | o **SMTP username** da OCI (`ocid1.user...@ocid1.tenancy....lr.com`) |
| **Authentication → Secret** | o **SMTP password** gerado na OCI |
| **Name** | `oci` (identificador da rota) |

### 5.2 Estratégia de saída (Outbound Strategy → Routing)

Expressão que escolhe a rota por mensagem — entrega **local** para o próprio domínio e manda o
resto pelo relay `oci`:

```
IF   is_local_domain(rcpt_domain)
THEN 'local'
ELSE 'oci'
```

> É isso que faz "e-mail interno fica local, e-mail externo vai pela OCI".

---

## 6. DNS do domínio (resumo)

| Tipo | Nome | Valor |
|------|------|-------|
| **A** | `mail.dominio` | IP do servidor |
| **MX** | `dominio` | `mail.dominio` (prioridade 10) |
| **TXT (SPF)** | `dominio` | `v=spf1 include:<include-da-OCI> ~all` |
| **CNAME/TXT (DKIM)** | conforme a OCI | registros que a OCI fornecer |
| **TXT (DMARC)** | `_dmarc.dominio` | `v=DMARC1; p=none; rua=mailto:postmaster@dominio` |

> Os valores exatos de SPF/DKIM vêm do console da OCI (Email Delivery). PTR (DNS reverso) do IP
> ajuda na entrega de e-mails que saem direto (não pelo relay), mas com relay a reputação é da OCI.

---

## 7. Certificado TLS (padrão: reaproveitando o cert do nginx-proxy-manager)

**Este é o método padrão deste setup** (não é opcional): como o **NPM está sempre no mesmo host** e
já emite/renova o cert Let's Encrypt de `mail.<domínio>`, o Stalwart **reaproveita esse mesmo cert**.
Sem isso, o Stalwart loga `No TLS certificates available (total=0)` e serve um cert **self-signed** —
o que gera aviso de segurança em clientes de e-mail externos que conectam direto em 465/587/993.

> ⚠️ **Não** se usa o ACME próprio do Stalwart aqui, porque as portas **80/443 são do NPM** (conflito
> no desafio). E o macro `%{file:...}%` só vale para chaves do arquivo de config local, **não** do
> banco. Por isso o cert entra como **objeto no banco com referência a arquivo** (`@type: File`), que
> funciona a partir do banco e sempre relê o arquivo (mantido atualizado pelo script + cron).

**Passos (fazer sempre):**

1. O NPM já mantém um cert Let's Encrypt para `mail.dominio` em
   `nginx-proxy-manager/letsencrypt/live/npm-<N>/` (descubra o `<N>` com
   `openssl x509 -in .../cert.pem -noout -ext subjectAltName`).
2. Os arquivos do NPM são `root`/`600` e o Stalwart roda como **uid 2000** → não consegue ler.
   O script [`sync-cert.sh`](sync-cert.sh) copia `fullchain.pem`/`privkey.pem` para `./tls/`
   (chown 2000, chmod 640) e **reinicia o Stalwart só quando o cert muda**.
3. Cron diário em `/etc/cron.d/stalwart-cert`:
   ```
   20 3 * * * root /home/ubuntu/apps/mail/sync-cert.sh >> /home/ubuntu/apps/mail/tls/sync.log 2>&1
   ```
4. Volume no compose: `- ./tls:/opt/tls:ro` (já incluído acima).
5. **No webadmin** (Settings → **TLS → Certificates → Add**): crie um certificado usando
   **referência a arquivo** (tipo **File**, não colar PEM), apontando para os arquivos montados:
   - **Certificate / chain:** `/opt/tls/fullchain.pem`
   - **Private key:** `/opt/tls/privkey.pem`
   - Marque como **default** (define `defaultCertificateId`).

   > Use o tipo **File**/`filePath`. Se colar o PEM inline, na renovação (a cada ~60-90 dias) o cert
   > no banco fica velho — a referência a arquivo evita isso, pois o Stalwart relê o arquivo (que o
   > cron atualiza).

**Verificar:**
```bash
echo | openssl s_client -connect mail.dominio:993 2>/dev/null | openssl x509 -noout -issuer -subject
# deve mostrar issuer Let's Encrypt e subject CN=mail.dominio (não mais self-signed)
```

> O cert é servido por **SNI** = `mail.dominio`. Conexões pelo nome interno `stalwart-mail`
> (healthz e Roundcube) não casam com o SAN e caem no self-signed — inofensivo (Roundcube não
> verifica). Se quiser silenciar o warning `No TLS certificates available`, marque esse cert como
> **default** (Settings → TLS → `defaultCertificateId`).

### 7.1 Listener 587 (submission/STARTTLS) — criar sempre

O Stalwart só escuta nas portas que têm **listener configurado** — mesmo que o compose publique a
porta. A instalação padrão **não** traz o **`submission` (587/STARTTLS)** (só o `submissions`/465
com TLS implícito). Como usamos 587 para clientes externos, **crie-o** em
**Settings → Server → Listeners**:

- Espelhe o listener **`submissions` (465)** e mude: **Bind → `[::]:587`**, **Implicit TLS →
  desligado** (587 = STARTTLS; a 465 é implícito). Mantenha **Enable TLS ligado**.
- Reinicie o container para ligar a porta nova: `docker restart stalwart-mail`.

Conferir quais portas o Stalwart realmente escuta por dentro:
```bash
docker exec stalwart-mail sh -c 'cat /proc/net/tcp /proc/net/tcp6' \
  | awk '$4=="0A"{print $2}' | sed 's/.*://' | while read h; do printf "%d\n" "0x$h"; done | sort -nu
```
> A porta **143 (IMAP plano)** também não tem listener aqui — usamos só IMAPS/993. Pode remover
> `143` do mapeamento de portas do compose para evitar confusão.

---

## 8. Verificação / teste de envio

Testar **sem depender do cliente**, autenticando via 465 e vendo o log ao vivo:

```bash
# terminal 1 — acompanhar o log (o servidor deve estar com logging em debug)
docker logs -f stalwart-mail

# terminal 2 — enviar um teste autenticado (troque a senha/remetente/destino)
python3 - <<'PY'
import smtplib, ssl
from email.message import EmailMessage
ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
m = EmailMessage()
m["From"]="admin@seu-dominio.com.br"; m["To"]="voce@gmail.com"
m["Subject"]="Teste relay OCI"; m.set_content("teste")
s = smtplib.SMTP_SSL("127.0.0.1", 465, context=ctx, timeout=20)
s.login("admin@seu-dominio.com.br", "SENHA")
s.send_message(m); s.quit()
print("enviado")
PY
```

No log, o sucesso aparece como:
```
Connecting to remote server ... hostname="smtp.email.sa-saopaulo-1.oci.oraclecloud.com" remotePort=587
SMTP STARTTLS command ... version="TLSv1_2"
SMTP MAIL FROM ... code=250
SMTP RCPT TO  ... code=250
Message delivered ... code=250 details="Ok"
```

Testar a **conectividade** do container com o relay (use `bash`/`openssl`, **não** `sh` — veja
armadilhas):
```bash
docker exec stalwart-mail bash -c \
  "echo QUIT | openssl s_client -starttls smtp -connect smtp.email.sa-saopaulo-1.oci.oraclecloud.com:587 -crlf 2>&1 | head"
```

---

## 9. Armadilhas que já nos pegaram

1. **Caminho dos volumes.** A imagem v0.16 usa `/var/lib/stalwart` e `/etc/stalwart`, **não**
   `/opt/stalwart/...`. Se montar errado, o container sobe mas **não persiste** (perde tudo no
   recreate) e a config parece "sumir".

2. **Variável de admin.** v0.16 usa `STALWART_RECOVERY_ADMIN=admin:<senha>`.
   `STALWART_ADMIN_PASS` é **ignorada** (a versão gera uma senha temporária aleatória a cada boot).

3. **Porta 25 bloqueada na saída (OCI).** O relay **precisa** usar a **587** (STARTTLS). Se ficar
   em 25, dá `Connection timed out (os error 110)` na fila.

4. **Teste de rede com o shell errado.** O `/bin/sh` do container é **dash**, que **não** suporta
   `/dev/tcp`. Testes de porta com `sh -c '... /dev/tcp/...'` dão **falso "bloqueado"**. Use
   `bash -c`, `curl` ou `openssl` (o container tem os três).

5. **Erro "antigo" na fila.** Depois de corrigir a config, mensagens já na fila continuam mostrando
   o **último erro** até a próxima tentativa (retry com backoff exponencial). Force "Retry" na fila
   ou mande um e-mail novo para confirmar — não confie no erro exibido de uma mensagem antiga.

6. **Config do Stalwart v0.16 fica no banco (RocksDB), não em arquivo.** O `etc/config.json` é só
   bootstrap. A API REST `/api/settings` foi **removida** — configuração é via **webadmin (UI)**,
   JMAP ou `stalwart-cli apply`. Ou seja: **configure o relay pela UI**, não tente editar arquivo.

7. **Approved Senders da OCI.** Cada endereço `From` precisa estar aprovado na OCI, senão o
   `MAIL FROM` daquele remetente é recusado (mesmo com tudo o resto certo).

---

## 10. Backup e restauração

**Backup** (dados do Stalwart = contas, e-mails, config, fila):
```bash
# a quente (rápido) ou pare o container antes para consistência total
docker exec stalwart-mail sh -c 'cd / && tar czf - var/lib/stalwart etc/stalwart' > stalwart-backup.tar.gz
```

Com os volumes corretos, os dados também estão em `./data` e `./etc` no host — dá para fazer backup
direto dessas pastas (com o container parado).

**Restaurar** em outro servidor:
```bash
docker compose stop stalwart-mail
# extraia o tar para dentro de ./data e ./etc (mantendo a estrutura var/lib/stalwart e etc/stalwart)
docker run --rm --user 0:0 -v "$PWD/data:/d" -v "$PWD/etc:/e" alpine chown -R 2000:2000 /d /e
docker compose up -d stalwart-mail
```
> O processo do Stalwart roda como **uid 2000** — por isso o `chown -R 2000:2000` nos dados.

---

## Referência rápida

| Item | Valor |
|------|-------|
| Imagem | `stalwartlabs/stalwart:latest` (v0.16) |
| Dados (no container) | `/var/lib/stalwart` (RocksDB) |
| Config bootstrap | `/etc/stalwart/config.json` |
| UID do processo | `2000:2000` |
| Webadmin | porta `8080` |
| Relay OCI | `smtp.email.<região>.oci.oraclecloud.com:587` (STARTTLS + AUTH) |
| Admin de recuperação | `STALWART_RECOVERY_ADMIN=admin:<senha>` |
| TLS | cert LE do **NPM** (`mail.<domínio>`), montado em `/opt/tls` via `sync-cert.sh` + cron; objeto Certificate no webadmin com `@type File` |
| Listeners em uso | `25, 465, 587, 993, 995, 4190, 8080` (587 = criado manualmente; 995 = POP3S p/ Gmail; `143` não usado) |
| Portas do NPM | `80/443` (por isso o Stalwart não usa ACME próprio) |
