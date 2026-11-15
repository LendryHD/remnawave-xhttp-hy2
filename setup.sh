#!/usr/bin/env bash
# Дополнение к eGames: XHTTP + Hysteria2, не устанавливает Remnawave/NetBird.
set -Eeuo pipefail
set +x  # Никогда не печатать API-токен в трассировке shell
umask 077
APP=/opt/remnawave-hy2
PANEL_CERT=/opt/remnawave/xray-ssl
PANEL_SSL_CONTAINER=/var/lib/remnawave/configs/xray/ssl
# Выделенный непривилегированный пользователь SFTP. Не используем sudo-пользователя панели.
UPLOAD_USER=rw-hy2-upload
UPLOAD_HOME=/var/lib/remnawave-hy2-upload
STAGING="$UPLOAD_HOME/incoming"
CRED_DIR=/etc/remnawave-hy2
PANEL_API_URL=http://127.0.0.1:3000
SELF=$(readlink -f -- "${BASH_SOURCE[0]}")
log(){ printf '[hy2] %s\n' "$*"; }
die(){ printf '[ОШИБКА] %s\n' "$*" >&2; exit 1; }
require_root(){ [[ $EUID -eq 0 ]] || die 'Запустите от root'; }
valid_domain(){ [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] && [[ "$1" == *.* ]] && [[ ! "$1" =~ [.]\.|^[-]|[-]$ ]]; }
need_domain(){ valid_domain "$DOMAIN" || die 'Неверное имя домена'; }
usage(){ cat <<'HELP'
Remnawave XHTTP + Hysteria2 companion v0.2
  setup.sh node DOMAIN PANEL_IP
    Подготовить XHTTP, UDP/443, сертификаты и таймер (новая нода после eGames).
  setup.sh migrate DOMAIN PANEL_IP
    Подключить автообновление сертификата на УЖЕ РАБОТАЮЩЕЙ ноде; Caddy/Xray не изменяются.
  setup.sh panel DOMAIN NODE_PUBLIC_IP 'ssh-ed25519 AAAA...'
    Настроить отдельного SFTP-пользователя и таймер импорта сертификатов на панели.
  setup.sh api-setup DOMAIN NODE_UUID
    Скрыто запросить API-токен Remnawave, проверить его через GET ноды и сохранить только на панели (0600).
  setup.sh api-test DOMAIN | api-delete DOMAIN
  setup.sh node-sync DOMAIN PANEL_IP
  setup.sh panel-sync
  setup.sh panel-apply DOMAIN
  setup.sh status DOMAIN
  setup.sh cleanup-legacy-panel DOMAIN
    После успешной миграции отозвать ровно старый ключ hy2-transfer-temp (интерактивно).
  setup.sh cleanup-legacy-node DOMAIN
    Удалить старый /root/.ssh/hy2-transfer-key* после успешной передачи (интерактивно).

Важно: Скрипт не устанавливает Remnawave/NetBird, не создаёт hosts/inbounds в панели,
не меняет Caddy панели, MFA, REALITY и не настраивает каскады.
HELP
}
valid_uuid(){ [[ "$1" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; }
valid_endpoint(){ [[ "$1" =~ ^[a-zA-Z0-9.:_-]+$ ]]; }
validate_panel_host(){ valid_endpoint "$PANEL_HOST" || die 'Неверный адрес панели'; }

check_pair(){
  local cert="$1" key="$2" domain="$3" a b
  [[ -s "$cert" && -s "$key" ]] || return 1
  openssl x509 -in "$cert" -noout -checkhost "$domain" 2>/dev/null | grep -q 'does match' || return 1
  openssl x509 -in "$cert" -noout -checkend 604800 >/dev/null 2>&1 || return 1
  a=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1) || return 1
  b=$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1) || return 1
  [[ -n "$a" && "$a" == "$b" ]]
}
install_self(){
  install -d -m 700 "$APP"
  [[ "$SELF" == "$APP/setup.sh" ]] || install -m 700 "$SELF" "$APP/setup.sh"
}
write_node_templates(){
  local out="$APP/examples/$DOMAIN"
  install -d -m 700 "$out"
  cat > "$out/inbounds.json" <<EOF
[
  {
    "tag": "${DOMAIN}-XHTTP", "listen": "/dev/shm/xrxh.socket,0666",
    "protocol": "vless", "settings": {"clients": [], "decryption": "none"},
    "streamSettings": {"network": "xhttp", "security": "none",
      "xhttpSettings": {"mode": "auto", "path": "/xhttppath/"}}
  },
  {
    "tag": "${DOMAIN}-HY2", "listen": "0.0.0.0", "port": 443,
    "protocol": "hysteria", "settings": {"clients": [], "version": 2},
    "streamSettings": {"network": "hysteria", "security": "tls",
      "finalmask": {"quicParams": {"debug": false, "congestion": "bbr"}},
      "tlsSettings": {"alpn": ["h3"], "certificates": [{
        "keyFile": "${PANEL_SSL_CONTAINER}/${DOMAIN}/privkey.key",
        "certificateFile": "${PANEL_SSL_CONTAINER}/${DOMAIN}/fullchain.pem"
      }]}, "hysteriaSettings": {"version": 2}}
  }
]
EOF
  chmod 600 "$out/inbounds.json"
  log "JSON для панели: $out/inbounds.json (добавить два объекта в inbounds существующего профиля)"
}
configure_caddy(){
  local p=/opt/remnanode/Caddyfile backup
  [[ -f "$p" ]] || die 'Нет /opt/remnanode/Caddyfile. Сначала установите ноду eGames с Caddy.'
  docker inspect caddy-remnawave >/dev/null 2>&1 || die 'Не найден контейнер caddy-remnawave'
  if grep -Fq 'reverse_proxy unix+h2c//dev/shm/xrxh.socket' "$p"; then
    log 'Маршрут XHTTP уже есть; повторно не добавляем'
    return
  fi
  backup="$p.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$p" "$backup"
  python3 - "$p" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
old='''https://{$SELF_STEAL_DOMAIN} {
    bind unix/{$CADDY_SOCKET_PATH}
    root * /var/www/html
    try_files {path} /index.html
    file_server
}'''
new='''https://{$SELF_STEAL_DOMAIN} {
    bind unix/{$CADDY_SOCKET_PATH}

    handle /xhttppath/* {
        reverse_proxy unix+h2c//dev/shm/xrxh.socket {
            flush_interval -1
        }
    }

    handle {
        root * /var/www/html
        try_files {path} /index.html
        file_server
    }
}'''
if s.count(old)!=1: raise SystemExit('Шаблон Caddy eGames не совпадает. Ничего не изменено.')
p.write_text(s.replace(old,new))
PY
  if ! docker exec caddy-remnawave caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; then
    cp -a "$backup" "$p"
    die "Caddy validate не прошёл; восстановлена копия $backup"
  fi
  if ! docker restart caddy-remnawave >/dev/null || ! docker inspect caddy-remnawave --format '{{.State.Running}}' | grep -qx true; then
    cp -a "$backup" "$p"
    docker restart caddy-remnawave >/dev/null || true
    die "Caddy не запустился после изменения; восстановлена копия $backup"
  fi
  log "Caddy применён; резервная копия $backup"
}
service_timer(){
  local name="$1" cmd="$2" interval="$3"
  cat > "/etc/systemd/system/${name}.service" <<EOF
[Unit]
Description=Remnawave HY2 certificate sync ($name)
After=docker.service network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=${cmd}
EOF
  cat > "/etc/systemd/system/${name}.timer" <<EOF
[Unit]
Description=Remnawave HY2 certificate sync timer ($name)
[Timer]
OnBootSec=10min
OnUnitActiveSec=$interval
RandomizedDelaySec=5min
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now "${name}.timer" >/dev/null
}
install_node_sync(){
  install_self
  install -d -m 700 "$APP/keys"
  local key="$APP/keys/${DOMAIN}.ed25519"
  if [[ ! -e "$key" ]]; then
    ssh-keygen -q -t ed25519 -N '' -f "$key" -C "hy2-sync-${DOMAIN}" </dev/null
    chmod 600 "$key"
  fi
  [[ -r "$key.pub" ]] || die 'Не найден публичный ключ синхронизации'
  printf 'PANEL_HOST=%s\nUPLOAD_USER=%s\n' "$PANEL_HOST" "$UPLOAD_USER" > "$APP/node-${DOMAIN}.conf"
  chmod 600 "$APP/node-${DOMAIN}.conf"
  service_timer "rw-hy2-push-${DOMAIN}" "$APP/setup.sh node-sync $DOMAIN $PANEL_HOST" 12h
  log 'Публичный ключ для регистрации на панели:'
  cat "$key.pub"
  log "На ПАНЕЛИ: sudo bash setup.sh panel $DOMAIN NODE_PUBLIC_IP 'ПУБЛИЧНЫЙ_КЛЮЧ_ИЗ_ВЫВОДА'"
  log 'До регистрации ключа, проверки SSH fingerprint и первого успешного node-sync таймер не сможет доставлять сертификат.'
}
node_setup(){
  require_root; need_domain; validate_panel_host
  command -v docker >/dev/null || die 'Нужен Docker'
  command -v openssl >/dev/null || die 'Нужен openssl'
  command -v python3 >/dev/null || die 'Нужен python3'
  configure_caddy
  write_node_templates
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    ufw allow 443/udp comment 'Remnawave Hysteria2' >/dev/null
    log 'UFW: разрешён 443/udp'
  fi
  install_node_sync
}
migrate(){
  require_root; need_domain; validate_panel_host
  command -v docker >/dev/null || die 'Нужен Docker'
  docker inspect remnanode >/dev/null 2>&1 || die 'Не найдена существующая Remnawave Node'
  docker inspect caddy-remnawave >/dev/null 2>&1 || die 'Не найден существующий Caddy ноды'
  grep -Fq 'reverse_proxy unix+h2c//dev/shm/xrxh.socket' /opt/remnanode/Caddyfile || die 'XHTTP в Caddy отсутствует. Используйте режим node после проверки.'
  [[ -S /dev/shm/xrxh.socket ]] || die 'XHTTP не запущен: нет xrxh.socket'
  ss -lunp | grep -Eq ':[4]43[[:space:]]' || die 'Нет UDP/443 для Hysteria2'
  log 'REALITY, Caddyfile и конфигурация Xray не будут изменены.'
  install_node_sync
}

find_caddy_cert_dir(){
  local d
  d=$(docker exec caddy-remnawave sh -c "find /data/caddy/certificates -type f -name '${DOMAIN}.crt' 2>/dev/null | head -n 1" | tr -d '\r')
  [[ -n "$d" ]] || die 'Caddy не содержит сертификат домена'
  printf '%s' "${d%/*}"
}
node_sync(){
  require_root; need_domain
  validate_panel_host
  local lock="$APP/push-${DOMAIN}.lock" key="$APP/keys/${DOMAIN}.ed25519" tmp cert_dir
  [[ -r "$key" ]] || die 'Нет ключа отправки: установите режим node/migrate'
  exec 9>"$lock"; flock -n 9 || exit 0
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  cert_dir=$(find_caddy_cert_dir)
  docker cp "caddy-remnawave:$cert_dir/$DOMAIN.crt" "$tmp/fullchain.pem" >/dev/null
  docker cp "caddy-remnawave:$cert_dir/$DOMAIN.key" "$tmp/privkey.key" >/dev/null
  check_pair "$tmp/fullchain.pem" "$tmp/privkey.key" "$DOMAIN" || die 'Невалидный сертификат/ключ или срок менее 7 дней'
  # OpenSSH scp по умолчанию использует SFTP; на панели ключ ограничен sftp-server.
  scp -B -q -i "$key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
    "$tmp/fullchain.pem" "$tmp/privkey.key" \
    "${UPLOAD_USER}@${PANEL_HOST}:${STAGING}/${DOMAIN}/" || die 'SFTP недоступен. Проверьте регистрацию ключа и known_hosts.'
  install -d -m 700 "$APP/state"
  date -Is > "$APP/state/$DOMAIN.sent-ok"
  chmod 600 "$APP/state/$DOMAIN.sent-ok"
  log "Сертификат $DOMAIN отправлен на панель"
}
panel_setup(){
  require_root; need_domain
  [[ "$NODE_IP" =~ ^[0-9a-fA-F:.]+$ ]] || die 'Неверный IP-адрес ноды'
  [[ "$PUBLIC_KEY" =~ ^ssh-ed25519[[:space:]]+[a-zA-Z0-9+/=]+([[:space:]]+[a-zA-Z0-9_.@-]+)?$ ]] || die 'Неверный формат публичного ключа Ed25519'
  command -v useradd >/dev/null || die 'Нужен useradd'
  local sftp=/usr/lib/openssh/sftp-server
  [[ -x "$sftp" ]] || die "Нет $sftp; проверьте пакет openssh-sftp-server"
  install_self
  if ! id "$UPLOAD_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "$UPLOAD_HOME" --shell /bin/sh "$UPLOAD_USER"
    passwd -l "$UPLOAD_USER" >/dev/null 2>&1 || true
  fi
  [[ "$(getent passwd "$UPLOAD_USER" | cut -d: -f6)" == "$UPLOAD_HOME" ]] || die 'Уже существующий SFTP-пользователь имеет другой HOME'
  [[ "$(id -Gn "$UPLOAD_USER")" != *sudo* ]] || die 'SFTP-пользователь состоит в группе sudo'
  # HOME и .ssh защищены от изменения самим пользователем SFTP.
  chown root:root "$UPLOAD_HOME"; chmod 755 "$UPLOAD_HOME"
  install -d -m 755 -o root -g root "$UPLOAD_HOME/.ssh"
  local auth="$UPLOAD_HOME/.ssh/authorized_keys"
  touch "$auth"; chown root:root "$auth"; chmod 644 "$auth"
  install -d -m 700 -o "$UPLOAD_USER" -g "$(id -gn "$UPLOAD_USER")" "$STAGING"
  install -d -m 700 -o "$UPLOAD_USER" -g "$(id -gn "$UPLOAD_USER")" "$STAGING/$DOMAIN"
  install -d -m 700 "$PANEL_CERT/$DOMAIN"
  local key_b64
  key_b64=$(awk '{print $2}' <<< "$PUBLIC_KEY")
  if ! grep -Fq "$key_b64" "$auth"; then
    printf 'from="%s",restrict,command="%s -d %s/%s" %s\n' \
      "$NODE_IP" "$sftp" "$STAGING" "$DOMAIN" "$PUBLIC_KEY" >> "$auth"
  fi
  service_timer rw-hy2-panel-sync "$APP/setup.sh panel-sync" 30min
  if ! docker inspect remnawave --format '{{range .Mounts}}{{println .Destination}}{{end}}' | grep -Fxq "$PANEL_SSL_CONTAINER"; then
    log "ВНИМАНИЕ: в remnawave нет bind mount $PANEL_SSL_CONTAINER"
    log "Добавьте /opt/remnawave/xray-ssl:$PANEL_SSL_CONTAINER:ro через Compose override."
  fi
  log "Ключ зарегистрирован для ноды $NODE_IP в отдельном непривилегированном аккаунте $UPLOAD_USER."
  log 'На ноде проверьте отпечаток панели и заполните /root/.ssh/known_hosts.'
}

panel_sync(){
  require_root
  command -v openssl >/dev/null || die 'Нужен openssl'
  local dir domain incoming target marker sum old
  docker inspect remnawave --format '{{range .Mounts}}{{println .Destination}}{{end}}' 2>/dev/null | grep -Fxq "$PANEL_SSL_CONTAINER" || die 'Каталог сертификатов не смонтирован в контейнер Remnawave; сначала настройте Compose override'
  shopt -s nullglob
  for dir in "$STAGING"/*/; do
    domain=$(basename "${dir%/}")
    valid_domain "$domain" || continue
    incoming="$dir"; target="$PANEL_CERT/$domain"
    [[ -f "$incoming/fullchain.pem" && -f "$incoming/privkey.key" ]] || continue
    check_pair "$incoming/fullchain.pem" "$incoming/privkey.key" "$domain" || { log "Пропущено: $domain — пара сертификата некорректна"; continue; }
    sum=$(sha256sum "$incoming/fullchain.pem" "$incoming/privkey.key" | sha256sum | awk '{print $1}')
    marker="$APP/state/$domain.sha256"; mkdir -p "$APP/state"
    old=$(cat "$marker" 2>/dev/null || true)
    if [[ "$sum" == "$old" ]] && [[ -s "$target/fullchain.pem" && -s "$target/privkey.key" ]]; then
      check_pair "$target/fullchain.pem" "$target/privkey.key" "$domain" && continue
    fi
    install -d -m 700 "$target"
    install -m 600 -o root -g root "$incoming/fullchain.pem" "$target/fullchain.pem.new"
    install -m 600 -o root -g root "$incoming/privkey.key" "$target/privkey.key.new"
    mv -f "$target/privkey.key.new" "$target/privkey.key"
    mv -f "$target/fullchain.pem.new" "$target/fullchain.pem"
    echo "$sum" > "$marker"
    date -Is > "$APP/state/$domain.needs-apply"
    log "Обновлён сертификат $domain; запрошено применение на ноде."
    panel_apply "$domain" || true
  done
  # Повторяем применение после временного сбоя API, даже если сертификат не менялся.
  for marker in "$APP"/state/*.needs-apply; do
    domain=$(basename "$marker" .needs-apply)
    panel_apply "$domain" || true
  done
}
api_files(){
  need_domain
  API_META="$CRED_DIR/node-${DOMAIN}.meta"
  API_TOKEN_FILE="$CRED_DIR/node-${DOMAIN}.token"
}
api_http(){
  # Секрет передаётся curl через временный файл заголовка (0600), а НЕ argv, env или URL.
  local method="$1" url="$2" code rc=0 header
  header=$(mktemp)
  chmod 600 "$header"
  printf 'Authorization: Bearer %s\n' "$(cat "$API_TOKEN_FILE")" > "$header"
  if [[ "$method" == POST ]]; then
    code=$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --max-time 15 \
      -X POST --header "@$header" -H 'Content-Type: application/json' \
      --data '{"forceRestart":true}' "$url") || rc=$?
  else
    code=$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --max-time 15 \
      --header "@$header" "$url") || rc=$?
  fi
  rm -f "$header"
  (( rc == 0 )) || return "$rc"
  printf '%s' "$code"
}
api_configure(){
  require_root; api_files
  valid_uuid "$NODE_UUID" || die 'UUID ноды должен соответствовать формату 8-4-4-4-12'
  [[ -t 0 ]] || die 'Для скрытого ввода ключа нужен интерактивный терминал (TTY)'
  command -v curl >/dev/null || die 'Нужен curl'
  install -d -m 700 "$CRED_DIR"
  local input temp old_file="" code
  IFS= read -rs -p "Вставьте API-токен Remnawave для ноды $DOMAIN (ввод скрыт): " input
  printf '\n'
  [[ "$input" =~ ^[a-zA-Z0-9._~-]{16,512}$ ]] || { unset input; die 'Неверный формат токена. Пробелы, переводы строк и спецсимволы запрещены.'; }
  temp=$(mktemp "$CRED_DIR/.token.XXXXXX")
  chmod 600 "$temp"
  printf '%s' "$input" > "$temp"; unset input
  # Проверить токен на API без изменения конфигурации панели/ноды.
  old_file=$API_TOKEN_FILE
  API_TOKEN_FILE=$temp
  code=$(api_http GET "$PANEL_API_URL/api/nodes/$NODE_UUID") || { rm -f "$temp"; die 'Панель API недоступна. Токен не сохранён.'; }
  API_TOKEN_FILE=$old_file
  if [[ "$code" != 200 ]]; then
    rm -f "$temp"
    die "API отклонило запрос (HTTP $code). Проверьте UUID, токен и права nodes:read/nodes:write; токен не сохранён."
  fi
  mv -f "$temp" "$API_TOKEN_FILE"
  printf '%s\n' "$NODE_UUID" > "$API_META"
  chmod 600 "$API_META" "$API_TOKEN_FILE"
  log "Ключ проверен через API и сохранён в файле root-only $API_TOKEN_FILE."
  log 'Он не хранится в коде GitHub и не передаётся в аргументах команды.'
}
api_test(){
  require_root; api_files
  [[ -s "$API_TOKEN_FILE" && -s "$API_META" ]] || die 'Сначала выполните api-setup'
  local uuid code
  uuid=$(cat "$API_META")
  valid_uuid "$uuid" || die 'Сохранённый UUID некорректен'
  code=$(api_http GET "$PANEL_API_URL/api/nodes/$uuid") || die 'Нет связи с локальным Remnawave API'
  log "Проверка API для $DOMAIN: HTTP $code (должен быть 200)"
  [[ "$code" == 200 ]]
}
api_delete(){
  require_root; api_files
  rm -f "$API_TOKEN_FILE" "$API_META"
  log "Локальные API-данные для $DOMAIN удалены. Сам токен нужно отозвать также в панели Remnawave."
}
panel_apply(){
  require_root
  DOMAIN="$1"; api_files
  [[ -e "$APP/state/$DOMAIN.needs-apply" ]] || { log 'Применение не требуется (нет маркера обновления).'; return 0; }
  [[ -s "$API_TOKEN_FILE" && -s "$API_META" ]] || { log "Для $DOMAIN требуется ручной Force Restart конкретной ноды: API-ключ не настроен."; return 1; }
  local uuid code
  uuid=$(cat "$API_META")
  valid_uuid "$uuid" || { log 'UUID ноды в конфигурации повреждён'; return 1; }
  # Endpoint и forceRestart=true сверены с Remnawave Docs. Только целевая нода.
  code=$(api_http POST "$PANEL_API_URL/api/nodes/$uuid/actions/restart") || { log 'Ошибка соединения с API. Маркер оставлен.'; return 1; }
  case "$code" in
    200|202|204)
      rm -f "$APP/state/$DOMAIN.needs-apply"
      log "API приняло запрос на Force Restart ноды $DOMAIN (HTTP $code). Проверяйте конечный сертификат отдельно."
      ;;
    *) log "API не приняло Force Restart (HTTP $code); маркер сохранён."; return 1;;
  esac
}
cleanup_legacy_panel(){
  require_root; need_domain
  local auth=/home/lendry/.ssh/authorized_keys keytag='hy2-transfer-temp'
  [[ -s "$PANEL_CERT/$DOMAIN/fullchain.pem" ]] || die 'Сначала убедитесь, что актуальный сертификат получен'
  [[ -f "$UPLOAD_HOME/.ssh/authorized_keys" ]] || die 'Новый SFTP-ключ не зарегистрирован'
  [[ -f "$APP/state/$DOMAIN.sha256" ]] || die 'Нет подтверждения первого импорта через panel-sync; сначала проверьте новую схему синхронизации'
  cmp -s "$STAGING/$DOMAIN/fullchain.pem" "$PANEL_CERT/$DOMAIN/fullchain.pem" || die 'Импортированный сертификат отличается от доставленного: очистка преждевременна'
  cmp -s "$STAGING/$DOMAIN/privkey.key" "$PANEL_CERT/$DOMAIN/privkey.key" || die 'Импортированный ключ отличается от доставленного: очистка преждевременна'
  [[ -f "$auth" ]] || { log 'Старый authorized_keys не найден'; return 0; }
  local count
  count=$(grep -Fc "$keytag" "$auth" || true)
  (( count > 0 )) || { log 'Ключ hy2-transfer-temp отсутствует'; return 0; }
  log "Найдено $count временных SSH-ключей с пометкой $keytag для удаления."
  [[ -t 0 ]] || die 'Нужен терминал для подтверждения'
  local yesno
  read -r -p 'Отозвать этот ключ из authorized_keys? [yes/NO] ' yesno
  [[ "$yesno" == yes ]] || { log 'Без изменений'; return 0; }
  local backup tmp
  backup="$auth.bak.$(date +%Y%m%d_%H%M%S)"
  cp -a "$auth" "$backup"
  tmp=$(mktemp)
  grep -Fv "$keytag" "$auth" > "$tmp" || true
  cat "$tmp" > "$auth"
  rm -f "$tmp"
  chmod 600 "$auth"
  log "Временный ключ отозван. Резервная копия: $backup"
}
cleanup_legacy_node(){
  require_root; need_domain
  local key=/root/.ssh/hy2-transfer-key
  [[ -f "$key" ]] || { log 'Старого SSH-ключа нет'; return 0; }
  [[ -s "$APP/keys/$DOMAIN.ed25519" ]] || die 'Новый ключ синхронизации ещё не установлен'
  [[ -s "$APP/state/$DOMAIN.sent-ok" ]] || die 'Новая схема отправки ещё не выполнила ни одной успешной передачи'
  [[ -t 0 ]] || die 'Нужен терминал для подтверждения'
  local yesno
  read -r -p 'Удалить временный /root/.ssh/hy2-transfer-key и .pub? [yes/NO] ' yesno
  [[ "$yesno" == yes ]] || { log 'Без изменений'; return 0; }
  rm -f "$key" "$key.pub"
  log 'Старый ключ удалён с ноды; убедитесь, что он ранее отозван и на панели.'
}

status(){
  need_domain
  printf 'Caddy XHTTP: '; grep -Fq 'reverse_proxy unix+h2c//dev/shm/xrxh.socket' /opt/remnanode/Caddyfile 2>/dev/null && echo OK || echo NO
  printf 'XHTTP socket: '; test -S /dev/shm/xrxh.socket && echo OK || echo NO
  printf 'UDP/443: '; ss -lunp 2>/dev/null | grep -Eq ':[4]43[[:space:]]' && echo OK || echo NO
  printf 'Node sync timer: '; systemctl is-active "rw-hy2-push-$DOMAIN.timer" 2>/dev/null || true
}
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0
[[ $# -ge 1 ]] || { usage; exit 1; }
action="$1"; shift
case "$action" in
  node) [[ $# == 2 ]] || { usage; exit 1; }; DOMAIN="$1"; PANEL_HOST="$2"; node_setup;;
  migrate) [[ $# == 2 ]] || { usage; exit 1; }; DOMAIN="$1"; PANEL_HOST="$2"; migrate;;
  panel) [[ $# == 3 ]] || { usage; exit 1; }; DOMAIN="$1"; NODE_IP="$2"; PUBLIC_KEY="$3"; panel_setup;;
  api-setup) [[ $# == 2 ]] || { usage; exit 1; }; DOMAIN="$1"; NODE_UUID="$2"; api_configure;;
  api-test) DOMAIN="${1:?Укажите домен}"; api_test;;
  api-delete) DOMAIN="${1:?Укажите домен}"; api_delete;;
  node-sync) [[ $# == 2 ]] || { usage; exit 1; }; DOMAIN="$1"; PANEL_HOST="$2"; node_sync;;
  panel-sync) panel_sync;;
  status) DOMAIN="${1:?Укажите домен}"; status;;
  panel-apply) DOMAIN="${1:?Укажите домен}"; panel_apply "$DOMAIN";;
  cleanup-legacy-panel) DOMAIN="${1:?Укажите домен}"; cleanup_legacy_panel;;
  cleanup-legacy-node) DOMAIN="${1:?Укажите домен}"; cleanup_legacy_node;;
  *) usage; exit 1;;
esac