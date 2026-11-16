#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Мастер настройки на русском языке. Запускается только на сервере панели.
CONFIG_DIR=/etc/remnawave-hy2-sync
SELF=/usr/local/sbin/rw-hy2-cert-sync.sh
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
action=menu
if (( $# > 0 )); then action="$1"; fi
fail(){ printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }
ask(){
  local value
  read -r -p "$1 [$2]: " value
  REPLY="$value"
  if [[ -z "$REPLY" ]]; then REPLY="$2"; fi
}
valid_domain(){ [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{2,252}$ && "$1" == *.* && "$1" != *..* ]]; }
valid_uuid(){ [[ "$1" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; }
safe_cfg(){ valid_domain "$1" || fail 'Неверный домен'; CFG="$CONFIG_DIR/$1.conf"; }
setup_wizard(){
  [[ -t 0 ]] || fail 'Необходим интерактивный терминал.'
  echo '=== Hysteria2: синхронизация сертификатов Caddy -> Remnawave ==='
  echo 'Мастер запускается НА VPS ПАНЕЛИ. Не меняет REALITY, Bridge и Caddyfile.'
  ask 'Домен ноды' 'ru.synet.pw'; DOMAIN="$REPLY"
  valid_domain "$DOMAIN" || fail 'Неверный домен'
  ask 'IP-адрес SSH ноды' '168.113.156.10'; NODE_HOST="$REPLY"
  [[ "$NODE_HOST" =~ ^[a-zA-Z0-9.:_-]+$ ]] || fail 'Неверный IP-адрес'
  ask 'SSH-пользователь с доступом к Docker на ноде' 'root'; NODE_USER="$REPLY"
  [[ "$NODE_USER" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || fail 'Неверное имя пользователя'
  ask 'Порт SSH ноды' '22'; NODE_PORT="$REPLY"
  [[ "$NODE_PORT" =~ ^[0-9]{1,5}$ ]] && (( NODE_PORT > 0 && NODE_PORT <= 65535 )) || fail 'Неверный порт SSH'
  ask 'Путь к закрытому SSH-ключу на панели' '/usr/local/remnawave_reverse/ssh/id_ed25519'; NODE_SSH_KEY="$REPLY"
  [[ -r "$NODE_SSH_KEY" ]] || fail 'SSH-ключ не найден'
  ask 'Файл известных SSH-ключей нод (known_hosts)' '/usr/local/remnawave_reverse/ssh/known_hosts'; NODE_KNOWN_HOSTS="$REPLY"
  [[ -s "$NODE_KNOWN_HOSTS" ]] || fail 'Не найден known_hosts с проверенным отпечатком ноды'
  ask 'UUID ноды из панели Remnawave' ''; NODE_UUID="$REPLY"
  valid_uuid "$NODE_UUID" || fail 'Неверный UUID'
  ask 'Файл с API-токеном Remnawave на панели' '/usr/local/remnawave_reverse/token'; PANEL_TOKEN="$REPLY"
  if [[ ! -s "$PANEL_TOKEN" ]]; then
    echo 'API-токен не найден. Введите его, ввод скрыт:'
    local secret
    read -rs -p 'API-токен: ' secret; echo
    [[ -n "$secret" ]] || fail 'Токен пуст'
    PANEL_TOKEN="$CONFIG_DIR/$DOMAIN.token"
    printf '%s' "$secret" > "$PANEL_TOKEN"
    chmod 600 "$PANEL_TOKEN"
    unset secret
  fi
  safe_cfg "$DOMAIN"
  if [[ -f "$CFG" ]]; then
    ask 'Перезаписать имеющиеся настройки? (да/нет)' 'нет'
    [[ "$REPLY" == да ]] || { echo 'Настройки не изменены'; return; }
  fi
  local tmp
  tmp=$(mktemp "$CONFIG_DIR/.conf.XXXXXX")
  chmod 600 "$tmp"
  {
    printf 'DOMAIN=%q\n' "$DOMAIN"
    printf 'NODE_HOST=%q\n' "$NODE_HOST"
    printf 'NODE_USER=%q\n' "$NODE_USER"
    printf 'NODE_PORT=%q\n' "$NODE_PORT"
    printf 'NODE_SSH_KEY=%q\n' "$NODE_SSH_KEY"
    printf 'NODE_KNOWN_HOSTS=%q\n' "$NODE_KNOWN_HOSTS"
    printf 'NODE_UUID=%q\n' "$NODE_UUID"
    printf 'PANEL_TOKEN=%q\n' "$PANEL_TOKEN"
  } > "$tmp"
  mv -f "$tmp" "$CFG"
  echo "Настройки сохранены в $CFG (только root)."
  if ssh -n -i "$NODE_SSH_KEY" -p "$NODE_PORT" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$NODE_KNOWN_HOSTS" -o ConnectTimeout=8 "$NODE_USER@$NODE_HOST" 'docker inspect caddy-remnawave >/dev/null 2>&1'; then
    echo 'SSH и контейнер Caddy доступны.'
  else
    echo 'SSH или Docker пока недоступны; настройте авторизацию до первого копирования.'
  fi
  echo 'Следующий шаг: пункт 2 — копирование без перезапуска ноды.'
}
unit_name(){ echo "rw-hy2-$(echo "$1" | tr '.' '-')"; }
enable_timer(){
  local domain="$1" unit
  safe_cfg "$domain"
  [[ -r "$CFG" ]] || fail 'Сначала запустите мастер'
  [[ -s "$SELF" ]] || fail "Поместите скрипт по адресу $SELF"
  unit=$(unit_name "$domain")
  cat > "/etc/systemd/system/$unit.service" <<EOF
[Unit]
Description=HY2 Caddy certificate sync ($domain)
After=network-online.target docker.service
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash $SELF run $domain
EOF
  cat > "/etc/systemd/system/$unit.timer" <<EOF
[Unit]
Description=HY2 certificate check ($domain)
[Timer]
OnCalendar=*-*-* 04,16:00:00
RandomizedDelaySec=5min
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$unit.timer"
  echo "Автообновление включено: $unit.timer (дважды в сутки)"
}
show_status(){
  local file domain
  shopt -s nullglob
  for file in "$CONFIG_DIR"/*.conf; do
    domain=$(basename "$file" .conf)
    echo "Домен: $domain"
    systemctl list-timers "$(unit_name "$domain").timer" --no-pager || true
  done
}
menu_wizard(){
  local choice
  while true; do
    echo
    echo '=== Hysteria2: сертификаты Remnawave ==='
    echo '1) Настроить ноду (вопросы на русском)'
    echo '2) Скопировать сертификат на панель БЕЗ перезапуска'
    echo '3) Проверить / применить сертификат (Force Restart при изменении)'
    echo '4) Включить автоматическое обновление'
    echo '5) Показать состояние'
    echo '6) Выключить автоматическое обновление'
    echo '0) Выход'
    read -r -p 'Ваш выбор: ' choice
    case "$choice" in
      1) setup_wizard ;;
      2) ask 'Домен ноды' 'ru.synet.pw'; bash "$SELF" copy "$REPLY" ;;
      3) ask 'Домен ноды' 'ru.synet.pw'; bash "$SELF" run "$REPLY" ;;
      4) ask 'Домен ноды' 'ru.synet.pw'; enable_timer "$REPLY" ;;
      5) show_status ;;
      6) ask 'Домен ноды' 'ru.synet.pw'; safe_cfg "$REPLY"; systemctl disable --now "$(unit_name "$REPLY").timer" ;;
      0) break ;;
      *) echo 'Неверный пункт меню' ;;
    esac
  done
}
[[ "$EUID" -eq 0 ]] || fail 'Запускайте через sudo или от root'
case "$action" in
  menu) menu_wizard; exit 0 ;;
  setup) setup_wizard; exit 0 ;;
  enable) [[ $# -eq 2 ]] || fail 'Укажите домен'; enable_timer "$2"; exit 0 ;;
  disable) [[ $# -eq 2 ]] || fail 'Укажите домен'; safe_cfg "$2"; systemctl disable --now "$(unit_name "$2").timer"; exit 0 ;;
  status) show_status; exit 0 ;;
  copy|run)
    [[ $# -eq 2 ]] || fail 'Укажите домен'
    safe_cfg "$2"
    [[ -r "$CFG" ]] || fail 'Сначала запустите мастер'
    [[ "$(stat -c %u "$CFG")" == 0 && "$(stat -c %a "$CFG")" == 600 ]] || fail 'Небезопасные права файла настроек'
    source "$CFG"
    valid_domain "$DOMAIN" && [[ "$DOMAIN" == "$2" ]] || fail 'Ошибка домена в настройках'
    valid_uuid "$NODE_UUID" || fail 'Ошибка UUID'
    ;;
  *) fail 'Неизвестная команда' ;;
esac

TARGET="/opt/remnawave/xray-ssl/$DOMAIN"
STATE='/var/lib/remnawave-hy2-sync'
BACKUP="/var/backups/remnawave-hy2/$DOMAIN"

log(){ echo "[HY2 $DOMAIN] $*"; }
[[ $EUID == 0 ]] || { log 'Нужен root'; exit 1; }
[[ -r "$NODE_SSH_KEY" && -s "$PANEL_TOKEN" ]] || { log 'Нет SSH-ключа или API-токена eGames'; exit 1; }
[[ -r "$NODE_KNOWN_HOSTS" ]] || { log 'Нет подтверждённого known_hosts'; exit 1; }
valid_uuid "$NODE_UUID" || { log 'Заполните UUID ноды'; exit 1; }
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
if [[ "$action" == copy ]]; then
  log "Копирование завершено. Нода не перезапускалась."
  exit 0
fi
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
