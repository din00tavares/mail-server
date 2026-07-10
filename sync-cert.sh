#!/usr/bin/env bash
# Sincroniza o certificado Let's Encrypt gerenciado pelo nginx-proxy-manager (NPM) para uma pasta
# legível pelo processo do Stalwart (uid 2000) e reinicia o container SOMENTE quando o cert muda
# (ex.: após uma renovação do NPM). Rode como root (via cron). Idempotente e reutilizável.
#
# Configuração por variáveis de ambiente (ou pelo .env ao lado do script):
#   MAIL_DOMAIN        hostname do cert a procurar no NPM (ex.: mail.exemplo.com.br)  [obrigatório]
#   NPM_LE_DIR         pasta letsencrypt do NPM        (default: ../nginx-proxy-manager/letsencrypt)
#   CERT_DST           destino dos PEMs                (default: <dir-do-script>/tls)
#   STALWART_CONTAINER nome do container               (default: stalwart-mail)
#   STALWART_UID       uid do processo do Stalwart     (default: 2000)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# carrega MAIL_DOMAIN (e afins) do .env ao lado do script, se existir
[ -f "$HERE/.env" ] && . "$HERE/.env"

MAIL_DOMAIN="${MAIL_DOMAIN:?defina MAIL_DOMAIN (ex.: mail.exemplo.com.br) no .env ou no ambiente}"
NPM_LE_DIR="${NPM_LE_DIR:-$HERE/../nginx-proxy-manager/letsencrypt}"
DST="${CERT_DST:-$HERE/tls}"
CONTAINER="${STALWART_CONTAINER:-stalwart-mail}"
STALWART_UID="${STALWART_UID:-2000}"

# Descobre automaticamente o diretório do cert do NPM cujo SAN contém MAIL_DOMAIN
SRC=""
for d in "$NPM_LE_DIR"/live/npm-*; do
  [ -f "$d/cert.pem" ] || continue
  if openssl x509 -in "$d/cert.pem" -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:$MAIL_DOMAIN"; then
    SRC="$d"; break
  fi
done
[ -n "$SRC" ] || { echo "$(date '+%F %T') ERRO: cert de $MAIL_DOMAIN nao encontrado em $NPM_LE_DIR/live/npm-*"; exit 1; }

mkdir -p "$DST"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# -L resolve os symlinks do Let's Encrypt (live -> archive)
cp -L "$SRC/fullchain.pem" "$tmp/fullchain.pem"
cp -L "$SRC/privkey.pem"   "$tmp/privkey.pem"

changed=0
for f in fullchain.pem privkey.pem; do
  cmp -s "$tmp/$f" "$DST/$f" 2>/dev/null || changed=1
done

if [ "$changed" = "1" ]; then
  cp "$tmp/fullchain.pem" "$tmp/privkey.pem" "$DST/"
  chown "$STALWART_UID:$STALWART_UID" "$DST/fullchain.pem" "$DST/privkey.pem"
  chmod 640 "$DST/fullchain.pem" "$DST/privkey.pem"
  docker restart "$CONTAINER" >/dev/null 2>&1 || true
  echo "$(date '+%F %T') cert de $MAIL_DOMAIN atualizado (fonte: $SRC) + $CONTAINER reiniciado"
else
  echo "$(date '+%F %T') sem mudanca no cert de $MAIL_DOMAIN"
fi
