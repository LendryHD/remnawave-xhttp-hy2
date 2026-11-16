#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# ИЗМЕНИТЕ ПАРАМЕТРЫ ДЛЯ СВОЕЙ НОДЫ
DOMAIN='ru.synet.pw'
NODE_HOST='IP_НОДЫ'
NODE_USER='root'
NODE_PORT=22
NODE_SSH_KEY='/usr/local/remnawave_reverse/ssh/id_ed25519'
NODE_KNOWN_HOSTS='/usr/local/remnawave_reverse/ssh/known_hosts'
NODE_UUID='UUID_НОДЫ_ИЗ_ПАНЕЛИ'
PANEL_TOKEN='/usr/local/remnawave_reverse/token'

TARGET="/opt/remnawave/xray-ssl/$DOMAIN"
STATE='/var/lib/remnawave-hy2-sync'
BACKUP="/var/backups/remnawave-hy2/$DOMAIN"

log(){ echo "[HY2 $DOMAIN] $*"; }
[[ $EUID == 0 ]] || { log 'Нужен root'; exit 1; }
[[ -r "$NODE_SSH_KEY" && -s "$PANEL_TOKEN" ]] || { log 'Нет SSH-ключа или API-токена eGames'; exit 1; }
[[ -r "$NODE_KNOWN_HOSTS" ]] || { log 'Нет подтверждённого known_hosts'; exit 1; }
[[ "$NODE_UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || { log 'Заполните UUID ноды'; exit 1; }
# Remnawave должен видеть сертификаты как файлы внутри контейнера.
docker inspect remnawave --format '{{range .Mounts}}{{println .Destination}}{{end}}' | grep -Fxq '/var/lib/remnawave/configs/xray/ssl' \
  || { log 'Сначала подключите /opt/remnawave/xray-ssl к контейнеру remnawave'; exit 1; }

install -d -m 700 "$STATE"
exec 9>"$STATE/$DOMAIN.lock"
flock -n 9 || exit 0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

SSH=(ssh -i "$NODE_SSH_KEY" -p "$NODE_PORT" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$NODE_KNOWN_HOSTS" -o ConnectTimeout=10 "$NODE_USER@$NODE_HOST")
cert_path=$("${SSH[@]}" "docker exec caddy-remnawave find /data/caddy/certificates -type f -name '$DOMAIN.crt' -print -quit")
[[ "$cert_path" == /data/caddy/certificates/*"/$DOMAIN.crt" ]] || { log 'Caddy не нашёл сертификат домена'; exit 1; }
"${SSH[@]}" "docker exec caddy-remnawave cat '$cert_path'" > "$TMP/fullchain.pem"
"${SSH[@]}" "docker exec caddy-remnawave cat '${cert_path%.crt}.key'" > "$TMP/privkey.key"

# Отбрасываем неверный или устаревший сертификат и несовпадающий закрытый ключ.
openssl x509 -in "$TMP/fullchain.pem" -noout -checkhost "$DOMAIN" | grep -q 'does match' || { log 'Неверный домен сертификата'; exit 1; }
openssl x509 -in "$TMP/fullchain.pem" -noout -checkend 604800 >/dev/null || { log 'Сертификат истекает менее чем через 7 дней'; exit 1; }
cert_pub=$(openssl x509 -in "$TMP/fullchain.pem" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1)
key_pub=$(openssl pkey -in "$TMP/privkey.key" -pubout -outform DER | sha256sum | cut -d' ' -f1)
[[ "$cert_pub" == "$key_pub" ]] || { log 'Ключ и сертификат не совпадают'; exit 1; }

# В eGames токен уже существует на панели. Храним его только в root-only файле.
{
  printf 'Authorization: Bearer %s\n' "$(cat "$PANEL_TOKEN")"
  printf 'X-Forwarded-For: 127.0.0.1\nX-Forwarded-Proto: https\nX-Remnawave-Client-Type: browser\n'
} > "$TMP/headers"

api_get=$(curl -sS --noproxy '*' --max-time 15 -o "$TMP/get-body" -w '%{http_code}' \
  -H "@$TMP/headers" "http://127.0.0.1:3000/api/nodes/$NODE_UUID")
[[ "$api_get" == 200 ]] || { log "API Remnawave не подтвердил ноду (HTTP $api_get)"; exit 1; }

install -d -m 700 "$TARGET"
if ! { cmp -s "$TMP/fullchain.pem" "$TARGET/fullchain.pem" && cmp -s "$TMP/privkey.key" "$TARGET/privkey.key"; }; then
  # Оставляем ровно одну предыдущую рабочую пару для отката.
  install -d -m 700 "$BACKUP"
  if [[ -s "$TARGET/fullchain.pem" && -s "$TARGET/privkey.key" ]]; then
    install -m 600 "$TARGET/fullchain.pem" "$BACKUP/fullchain.pem"
    install -m 600 "$TARGET/privkey.key" "$BACKUP/privkey.key"
  fi
  install -m 600 "$TMP/fullchain.pem" "$TARGET/fullchain.pem.new"
  install -m 600 "$TMP/privkey.key" "$TARGET/privkey.key.new"
  mv -f "$TARGET/privkey.key.new" "$TARGET/privkey.key"
  mv -f "$TARGET/fullchain.pem.new" "$TARGET/fullchain.pem"
  touch "$STATE/$DOMAIN.pending"
  log 'Новый сертификат скопирован на панель'
fi

# Если прошлый перезапуск не удался, таймер повторит его в следующем цикле.
if [[ -f "$STATE/$DOMAIN.pending" ]]; then
  code=$(curl -sS --noproxy '*' --max-time 30 -o "$TMP/post-body" -w '%{http_code}' \
    -H "@$TMP/headers" -H 'Content-Type: application/json' \
    --data '{"forceRestart":true}' \
    "http://127.0.0.1:3000/api/nodes/$NODE_UUID/actions/restart")
  [[ "$code" =~ ^2[0-9][0-9]$ ]] || { log "Remnawave не принял Force Restart (HTTP $code)"; exit 1; }
  if grep -Eq '"success"[[:space:]]*:[[:space:]]*false' "$TMP/post-body"; then
    log 'API вернул success:false; требуется проверка'; exit 1
  fi
  rm -f "$STATE/$DOMAIN.pending"
  log 'Remnawave принял запрос перезапуска ноды'
else
  log 'Сертификат не изменился — перезапуск не требуется'
fi
