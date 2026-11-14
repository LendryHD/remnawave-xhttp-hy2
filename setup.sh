#!/usr/bin/env bash
# Дополнение к eGames: XHTTP + Hysteria2, не устанавливает Remnawave/NetBird.
set -Eeuo pipefail
umask 077
APP=/opt/remnawave-hy2
PANEL_CERT=/opt/remnawave/xray-ssl
PANEL_SSL_CONTAINER=/var/lib/remnawave/configs/xray/ssl
STAGING=/home/lendry/.hy2-transfer
SELF=$(readlink -f "$0")
log(){ printf '[hy2] %s\n' "$*"; }
die(){ printf '[ОШИБКА] %s\n' "$*" >&2; exit 1; }
require_root(){ [[ $EUID -eq 0 ]] || die 'Запустите от root'; }
valid_domain(){ [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] && [[ "$1" == *.* ]] && [[ ! "$1" =~ [.]\.|^[-]|[-]$ ]]; }
need_domain(){ valid_domain "$DOMAIN" || die 'Неверное имя домена'; }
usage(){ cat <<'HELP'
Remnawave XHTTP + Hysteria2 companion
  setup.sh node DOMAIN PANEL_IP [SSH_USER=lendry]
    Подготовить Caddy ноды, UDP/443, создать ключ и таймер доставки сертификата.
  setup.sh panel DOMAIN NODE_PUBLIC_IP NODE_PUBLIC_KEY [SSH_USER=lendry]
    Разрешить ключ только для SFTP, создать staging и таймер импорта сертификата.
  setup.sh node-sync DOMAIN PANEL_IP [SSH_USER=lendry]
  setup.sh panel-sync
  setup.sh status DOMAIN
  setup.sh panel-apply DOMAIN
    Если настроен локальный API-токен, отправить Force Restart только целевой ноды.
Скрипт НЕ устанавливает Remnawave, НЕ изменяет REALITY/NetBird/панельный Caddy,
НЕ добавляет inbounds/hosts в панель автоматически.
HELP
}
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
  install -m 700 "$SELF" "$APP/setup.sh"
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
node_setup(){
  require_root; need_domain
  command -v docker >/dev/null || die 'Нужен Docker'
  command -v openssl >/dev/null || die 'Нужен openssl'
  command -v python3 >/dev/null || die 'Нужен python3'
  install_self; configure_caddy; write_node_templates
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    ufw allow 443/udp comment 'Remnawave Hysteria2' >/dev/null
    log 'UFW: разрешён 443/udp'
  fi
  install -d -m 700 "$APP/keys"
  local key="$APP/keys/${DOMAIN}.ed25519"
  if [[ ! -f "$key" ]]; then
    ssh-keygen -q -t ed25519 -N '' -f "$key" -C "hy2-sync-${DOMAIN}" </dev/null
    chmod 600 "$key"
  fi
  printf '%s %s\n' "$PANEL_HOST" "$SSH_USER" > "$APP/node-${DOMAIN}.conf"
  chmod 600 "$APP/node-${DOMAIN}.conf"
  service_timer "rw-hy2-push-${DOMAIN}" "$APP/setup.sh node-sync $DOMAIN $PANEL_HOST $SSH_USER" 12h
  log 'Публичный ключ для регистрации на панели:'
  cat "$key.pub"
  log "На ПАНЕЛИ: bash setup.sh panel $DOMAIN NODE_PUBLIC_IP 'ПУБЛИЧНЫЙ_КЛЮЧ_ОДНОЙ_СТРОКОЙ' $SSH_USER"
  log 'Таймер создан. До регистрации ключа на панели передача сертификата не заработает.'
}
find_caddy_cert_dir(){
  local d
  d=$(docker exec caddy-remnawave sh -c "find /data/caddy/certificates -type f -name '${DOMAIN}.crt' 2>/dev/null | head -n 1" | tr -d '\r')
  [[ -n "$d" ]] || die 'Caddy не содержит сертификат домена'
  printf '%s' "${d%/*}"
}
node_sync(){
  require_root; need_domain
  local lock="$APP/push-${DOMAIN}.lock" key="$APP/keys/${DOMAIN}.ed25519" tmp cert_dir
  [[ -r "$key" ]] || die 'Нет ключа отправки: установите режим node'
  exec 9>"$lock"; flock -n 9 || exit 0
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  cert_dir=$(find_caddy_cert_dir)
  docker cp "caddy-remnawave:$cert_dir/$DOMAIN.crt" "$tmp/fullchain.pem" >/dev/null
  docker cp "caddy-remnawave:$cert_dir/$DOMAIN.key" "$tmp/privkey.key" >/dev/null
  check_pair "$tmp/fullchain.pem" "$tmp/privkey.key" "$DOMAIN" || die 'Невалидный сертификат/ключ или срок менее 7 дней'
  # OpenSSH scp по умолчанию использует SFTP; на панели ключ ограничен sftp-server.
  scp -B -q -i "$key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
    "$tmp/fullchain.pem" "$tmp/privkey.key" \
    "${SSH_USER}@${PANEL_HOST}:${STAGING}/${DOMAIN}/" || die 'SFTP недоступен. Проверьте регистрацию ключа и known_hosts.'
  log "Сертификат $DOMAIN отправлен на панель"
}
panel_setup(){
  require_root; need_domain
  [[ "$NODE_IP" =~ ^[0-9a-fA-F:.]+$ ]] || die 'Неверный IP ноды'
  [[ "$PUBLIC_KEY" =~ ^ssh-ed25519[[:space:]]+[a-zA-Z0-9+/=]+([[:space:]]+[a-zA-Z0-9_.@-]+)?$ ]] || die 'Неверный формат публичного ключа Ed25519'
  id "$SSH_USER" >/dev/null || die 'SSH-пользователь отсутствует'
  install_self
  install -d -m 700 -o "$SSH_USER" -g "$(id -gn "$SSH_USER")" "$STAGING"
  install -d -m 700 -o "$SSH_USER" -g "$(id -gn "$SSH_USER")" "$STAGING/$DOMAIN"
  install -d -m 700 "$PANEL_CERT/$DOMAIN"
  # Один ключ — одна нода; только SFTP, IP-ограничение и запрет туннелей/PTY.
  local home sshdir auth sftp
  home=$(getent passwd "$SSH_USER" | cut -d: -f6)
  local sshgroup; sshgroup=$(id -gn "$SSH_USER")
  sshdir="$home/.ssh"; auth="$sshdir/authorized_keys"
  install -d -m 700 -o "$SSH_USER" -g "$sshgroup" "$sshdir"
  touch "$auth"; chown "$SSH_USER:$SSH_USER" "$auth"; chmod 600 "$auth"
  sftp=/usr/lib/openssh/sftp-server
  [[ -x "$sftp" ]] || die "Нет $sftp; проверьте OpenSSH sftp-server"
  # Публичный ключ только одна строка (без переводов), не добавляем второй раз.
  local key_b64
  key_b64=$(awk '{print $2}' <<< "$PUBLIC_KEY")
  if ! grep -Fq "$key_b64" "$auth"; then
    printf 'from="%s",restrict,command="%s -d %s/%s" %s\n' \
      "$NODE_IP" "$sftp" "$STAGING" "$DOMAIN" "$PUBLIC_KEY" >> "$auth"
  fi
  chmod 600 "$auth"
  service_timer rw-hy2-panel-sync "$APP/setup.sh panel-sync" 30min
  if ! docker inspect remnawave --format '{{range .Mounts}}{{println .Destination}}{{end}}' | grep -Fxq "$PANEL_SSL_CONTAINER"; then
    log "ВНИМАНИЕ: в remnawave нет bind mount $PANEL_SSL_CONTAINER"
    log "Добавьте /opt/remnawave/xray-ssl:$PANEL_SSL_CONTAINER:ro через Compose override, затем пересоздайте только remnawave."
  fi
  log "Ключ зарегистрирован для $NODE_IP; staging: $STAGING/$DOMAIN"
  log 'Для SSH-первого подключения проверьте отпечаток панели и заполните known_hosts на ноде.'
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
panel_apply(){
  local d="$1" cfg="/etc/remnawave-hy2/restart-${1}.env"
  local PANEL_API_URL= NODE_UUID= API_TOKEN=
  [[ -e "$APP/state/$d.needs-apply" ]] || return 0
  if [[ ! -r "$cfg" ]]; then
    log "Для $d требуется Force Restart ноды в панели; опциональный API-файл $cfg ещё не настроен."
    return 1
  fi
  # Файл настроек доступен только root и не загружается из сети.
  # shellcheck disable=SC1090
  source "$cfg"
  [[ "$PANEL_API_URL" == 'http://127.0.0.1:3000' ]] || { log 'API разрешён только через loopback панели'; return 1; }
  [[ "$NODE_UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || { log "Некорректный UUID для $d"; return 1; }
  [[ -n "$API_TOKEN" ]] || { log "Нет API-токена для $d"; return 1; }
  local http
  http=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
    -X POST -H "Authorization: Bearer $API_TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"forceRestart":true}' \
    "$PANEL_API_URL/api/nodes/$NODE_UUID/actions/restart") || { log "Ошибка API для $d"; return 1; }
  if [[ "$http" == 200 || "$http" == 202 || "$http" == 204 ]]; then
    rm -f "$APP/state/$d.needs-apply"
    log "Force Restart через API отправлен для $d (HTTP $http)."
  else
    log "Force Restart через API не выполнен (HTTP $http): проверьте токен/права/UUID."
    return 1
  fi
}
status(){
  need_domain
  printf 'Caddy XHTTP: '; grep -Fq 'reverse_proxy unix+h2c//dev/shm/xrxh.socket' /opt/remnanode/Caddyfile 2>/dev/null && echo OK || echo NO
  printf 'XHTTP socket: '; test -S /dev/shm/xrxh.socket && echo OK || echo NO
  printf 'UDP/443: '; ss -lunp 2>/dev/null | grep -Eq ':[4]43[[:space:]]' && echo OK || echo NO
  printf 'Node sync timer: '; systemctl is-active "rw-hy2-push-$DOMAIN.timer" 2>/dev/null || true
}
[[ $# -ge 1 ]] || { usage; exit 1; }
action="$1"; shift
case "$action" in
  node) [[ $# -ge 2 ]] || { usage; exit 1; }; DOMAIN="$1"; PANEL_HOST="$2"; SSH_USER="${3:-lendry}"; node_setup;;
  panel) [[ $# -ge 3 ]] || { usage; exit 1; }; DOMAIN="$1"; NODE_IP="$2"; PUBLIC_KEY="$3"; SSH_USER="${4:-lendry}"; panel_setup;;
  node-sync) [[ $# -ge 2 ]] || { usage; exit 1; }; DOMAIN="$1"; PANEL_HOST="$2"; SSH_USER="${3:-lendry}"; node_sync;;
  panel-sync) panel_sync;;
  status) DOMAIN="${1:?Укажите домен}"; status;;
  panel-apply) require_root; DOMAIN="${1:?Укажите домен}"; panel_apply "$DOMAIN";;
  *) usage; exit 1;;
esac