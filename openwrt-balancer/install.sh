#!/bin/sh
# Synet Remnawave XRAY_JSON bridge for OpenWrt/PassWall2
set -eu
umask 077
BASE=/etc/synet-balancer
LIB=/usr/libexec/synet-balancer
INIT=/etc/init.d/synet-balancer
PORT=19080

say() { printf '\n%s\n' "$*"; }
die() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die 'Запустите от root.'
[ -r /etc/openwrt_release ] && command -v uci >/dev/null 2>&1 || die 'Этот установщик предназначен только для OpenWrt.'
command -v opkg >/dev/null 2>&1 || die 'Требуется opkg (OpenWrt 24.10); apk пока не поддерживается.'
command -v curl >/dev/null 2>&1 && curl -V >/dev/null 2>&1 || die 'curl повреждён; исправьте curl/libcurl до установки.'

say '=== Synet: Remnawave Xray JSON → локальный SOCKS5 → PassWall2 ==='
say 'Менять существующие DNS, маршруты, подписки и выбранный узел PassWall2 не будем.'

if [ "${1:-}" = 'status' ]; then
    [ -x "$INIT" ] && "$INIT" status || true
    command -v ss >/dev/null 2>&1 && ss -lnt | grep ":$PORT " || true
    exit 0
fi

SUB=''
for i in $(seq 0 39); do
    n=$(uci -q get "passwall2.@subscribe_list[$i].remark" 2>/dev/null || true)
    [ "$n" = 'synet' ] || continue
    SUB=$(uci -q get "passwall2.@subscribe_list[$i].url" 2>/dev/null || true)
    break
done
if [ -n "$SUB" ]; then
    say 'Найдена сохранённая подписка synet в PassWall2 (ссылка не выводится).'
    printf 'Использовать её? [Y/n]: '
    IFS= read -r ok || true
    case "$ok" in n|N) SUB='';; esac
fi
if [ -z "$SUB" ]; then
    say 'Вставьте HTTPS-ссылку Remnawave. Ввод скрыт:'
    stty -echo 2>/dev/null || true
    IFS= read -r SUB || true
    stty echo 2>/dev/null || true
    printf '\n'
fi
case "$SUB" in https://*) :;; *) die 'Допускается только HTTPS-ссылка.';; esac

# Xray-core takes about 27 MiB after unpacking. Keep headroom for the
# configuration and normal router operations; never force an install on a full overlay.
if ! command -v xray >/dev/null 2>&1; then
    free_kb=$(df -Pk /overlay 2>/dev/null | awk 'NR == 2 {print $4}')
    case "$free_kb" in
        ''|*[!0-9]*) die 'Не удалось определить свободное место /overlay; установка остановлена.' ;;
    esac
    if [ "$free_kb" -lt 36864 ]; then
        free_mb=$((free_kb / 1024))
        say "Свободно в /overlay: ${free_mb} МБ. Минимум 36 МБ для безопасной установки Xray-core."
        say 'Это ограничение хранилища, не ошибка версии OpenWrt или Remnawave.'
        die 'Увеличьте /overlay (extroot/внешний накопитель) или освободите место. Ничего не удаляем автоматически.'
    fi
fi

say 'Выбираю режим Xray (без opkg upgrade)...'
MODE=persistent
if ! command -v xray >/dev/null 2>&1; then
    free_overlay=$(df -Pk /overlay | awk 'NR==2 {print $4}')
    case "$free_overlay" in ''|*[!0-9]*) die 'Не удалось определить свободное место /overlay.' ;; esac
    if [ "$free_overlay" -lt 36864 ]; then
        MODE=ram
        [ "$(uname -m)" = aarch64 ] || die 'RAM-режим поддерживает только архитектуру aarch64.'
        free_tmp=$(df -Pk /tmp | awk 'NR==2 {print $4}')
        free_mem=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
        [ "$free_tmp" -ge 55000 ] || die 'Нужно >=55 МБ свободно в /tmp.'
        [ "$free_mem" -ge 75000 ] || die 'Нужно >=75 МБ доступной RAM для пробного запуска.'
        say 'RAM-режим: xray-core будет извлекаться из .ipk в /tmp (без установки во flash).'
        say 'После перезагрузки загрузка Xray повторится автоматически.'
    fi
fi
need=''
command -v jq >/dev/null 2>&1 || need="$need jq"
if [ "$MODE" = persistent ]; then
    command -v xray >/dev/null 2>&1 || need="$need xray-core"
fi
if [ -n "$need" ]; then
    say "Установка зависимостей:$need"
    opkg update || die 'Не удалось обновить списки пакетов.'
    # shellcheck disable=SC2086
    opkg install $need || die "Не удалось установить:$need. Сеть и правила PassWall2 не менялись."
fi
command -v jq >/dev/null 2>&1 || die 'jq не установлен.'

mkdir -p "$BASE" "$LIB"
chmod 700 "$BASE" "$LIB"
# Prevent subscription URLs from appearing in process lists of curl.
# Escape special characters per curl --config format.
escaped=$(printf '%s' "$SUB" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf 'url = "%s"\n' "$escaped" > "$BASE/curl.conf"
chmod 600 "$BASE/curl.conf"
unset SUB escaped
printf '%s\n' "$PORT" > "$BASE/port"
printf '%s\n' "$MODE" > "$BASE/mode"
chmod 600 "$BASE/port" "$BASE/mode"

cat > "$LIB/ensure-xray.sh" <<'ENSURE'
#!/bin/sh
# Pull xray-core from configured, signature-checked OpenWrt feed into tmpfs.
# No package installation and no postinst scripts.
set -eu
umask 077
BASE=/etc/synet-balancer
RUNTIME=/tmp/synet-balancer
[ "$(cat "$BASE/mode")" = ram ] || { command -v xray >/dev/null 2>&1; exit $?; }
[ -x "$RUNTIME/xray" ] && exit 0
mkdir -p "$RUNTIME"
chmod 700 "$RUNTIME"
LOCK="$RUNTIME/.download-lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    n=0
    while [ "$n" -lt 30 ]; do
        [ -x "$RUNTIME/xray" ] && exit 0
        sleep 2
        n=$((n + 1))
    done
    echo 'Загрузка Xray заблокирована другой попыткой' >&2
    exit 1
fi
cleanup() {
    rm -f "$RUNTIME/xray-new" "$RUNTIME"/xray-core_*.ipk
    rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
free_tmp=$(df -Pk /tmp | awk 'NR==2 {print $4}')
free_mem=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
[ "$free_tmp" -ge 55000 ] || { echo 'В /tmp недостаточно свободного места' >&2; exit 1; }
[ "$free_mem" -ge 75000 ] || { echo 'Недостаточно RAM для запуска Xray' >&2; exit 1; }
opkg update >/dev/null || { echo 'Не удалось обновить подписанные пакеты OpenWrt' >&2; exit 1; }
cd "$RUNTIME"
rm -f xray-core_*.ipk
opkg download xray-core >/dev/null || { echo 'Не удалось скачать xray-core' >&2; exit 1; }
pkg=$(find "$RUNTIME" -maxdepth 1 -name 'xray-core_*.ipk' -type f | head -1)
[ -n "$pkg" ] && [ -s "$pkg" ] || { echo 'Пакет xray-core не найден' >&2; exit 1; }
# OpenWrt 24.10 .ipk is tar.gz containing data.tar.gz and ./usr/bin/xray.
if ! (tar -xOzf "$pkg" ./data.tar.gz | tar -xOzf - ./usr/bin/xray) > "$RUNTIME/xray-new"; then
    echo 'Не удалось извлечь Xray из пакета' >&2
    exit 1
fi
[ -s "$RUNTIME/xray-new" ] || exit 1
chmod 700 "$RUNTIME/xray-new"
"$RUNTIME/xray-new" version >/dev/null 2>&1 || { echo 'Xray не исполняется на этом CPU' >&2; exit 1; }
mv "$RUNTIME/xray-new" "$RUNTIME/xray"
echo 'Xray размещён в RAM (/tmp), без установки во flash.'
ENSURE
chmod 700 "$LIB/ensure-xray.sh"

cat > "$LIB/serve.sh" <<'SERVE'
#!/bin/sh
set -eu
BASE=/etc/synet-balancer
LIB=/usr/libexec/synet-balancer
while ! "$LIB/ensure-xray.sh"; do
    echo 'Synet: повтор загрузки Xray через 30 секунд' >&2
    sleep 30
done
if [ "$(cat "$BASE/mode")" = ram ]; then
    exec /tmp/synet-balancer/xray run -c "$BASE/active.json"
fi
exec "$(command -v xray)" run -c "$BASE/active.json"
SERVE
chmod 700 "$LIB/serve.sh"

cat > "$LIB/update.sh" <<'UPDATE'
#!/bin/sh
set -eu
umask 077
BASE=/etc/synet-balancer
LIB=/usr/libexec/synet-balancer
PORT=$(cat "$BASE/port")
TEMP=$(mktemp "$BASE/download.XXXXXX")
CFG=$(mktemp "$BASE/checked.XXXXXX")
trap 'rm -f "$TEMP" "$CFG"' EXIT HUP INT TERM

# Only one instance at a time; avoid cron overlap.
LOCK="$BASE/.updating"
if ! mkdir "$LOCK" 2>/dev/null; then exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null || true; rm -f "$TEMP" "$CFG"' EXIT HUP INT TERM

if ! curl -fsSL --connect-timeout 10 --max-time 45 --retry 2 \
  -A 'Happ/1.0' -H 'Accept: application/json' \
  -K "$BASE/curl.conf" -o "$TEMP" 2>/dev/null; then
    echo 'Ошибка загрузки JSON; оставлена предыдущая рабочая конфигурация.' >&2
    exit 1
fi
[ -s "$TEMP" ] || { echo 'Пустая подписка; обновление отменено.' >&2; exit 1; }

# Intentionally accept ONLY one full Xray object, never URI-list or unknown wrappers.
# Preserve balancers, outbounds and routing. Limit ingress to one local SOCKS listener.
if ! jq -e --argjson p "$PORT" '
  if type != "object" or (.outbounds | type) != "array" or
     (.routing.balancers | type) != "array" or
     (.routing.balancers | length) == 0 then
    error("Ожидается один полный Xray JSON с routing.balancers")
  else
    .inbounds = (
      if (.inbounds | type) == "array" then
        [.inbounds[] | select(.protocol == "socks")][0:1]
      else [] end
      | if length == 0 then
          [{"tag":"socks","listen":"127.0.0.1","port":$p,"protocol":"socks","settings":{"udp":true}}]
        else map(.listen="127.0.0.1" | .port=$p) end
    )
  end
' "$TEMP" > "$CFG" 2>/dev/null; then
    echo 'Формат не поддержан: нужен полный Xray JSON с балансировщиком. Старый конфиг сохранён.' >&2
    exit 1
fi
if ! "$LIB/ensure-xray.sh"; then
    echo 'Xray не удалось подготовить; конфигурация не применена.' >&2
    exit 1
fi
if [ "$(cat "$BASE/mode")" = ram ]; then
    XRAY=/tmp/synet-balancer/xray
else
    XRAY=$(command -v xray)
fi
if ! "$XRAY" run -test -c "$CFG" >/dev/null 2>&1; then
    echo 'Xray отклонил JSON; конфигурация не применена.' >&2
    exit 1
fi
if [ -f "$BASE/active.json" ] && cmp -s "$CFG" "$BASE/active.json"; then
    echo 'Конфигурация не изменилась.'
    exit 0
fi
if [ -f "$BASE/active.json" ]; then
    cp "$BASE/active.json" "$BASE/previous.json"
    chmod 600 "$BASE/previous.json"
fi
mv "$CFG" "$BASE/active.json"
chmod 600 "$BASE/active.json"
if [ -x /etc/init.d/synet-balancer ]; then
    /etc/init.d/synet-balancer restart >/dev/null 2>&1 || {
        if [ -f "$BASE/previous.json" ]; then
            cp "$BASE/previous.json" "$BASE/active.json"
            /etc/init.d/synet-balancer restart >/dev/null 2>&1 || true
        fi
        echo 'Не удалось перезапустить службу; восстановлена предыдущая конфигурация.' >&2
        exit 1
    }
    sleep 2
    if command -v ss >/dev/null 2>&1; then
        bound=$(ss -lnt | grep -c "127.0.0.1:$PORT " || true)
    else
        bound=$(netstat -lnt 2>/dev/null | grep -c "127.0.0.1:$PORT " || true)
    fi
    if [ "$bound" = 0 ]; then
        if [ -f "$BASE/previous.json" ]; then
            cp "$BASE/previous.json" "$BASE/active.json"
            /etc/init.d/synet-balancer restart >/dev/null 2>&1 || true
        fi
        echo 'SOCKS-порт не открылся; старая конфигурация восстановлена.' >&2
        exit 1
    fi
fi
echo 'Проверенная конфигурация обновлена.'
UPDATE
chmod 700 "$LIB/update.sh"

cat > "$INIT" <<'INIT'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=95
STOP=15
start_service() {
  [ -s /etc/synet-balancer/active.json ] || return 1
  procd_open_instance
  procd_set_param command /usr/libexec/synet-balancer/serve.sh
  procd_set_param respawn 3600 5 5
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
INIT
chmod 755 "$INIT"

say 'Проверка формата подписки и конфигурации Xray...'
if ! "$LIB/update.sh"; then
    die 'Предпроверка не прошла. Ни настройки PassWall2, ни сеть не изменены. Подписка сохранена локально для диагностики.'
fi
"$INIT" enable
"$INIT" restart
sleep 2
if command -v ss >/dev/null 2>&1; then
    BOUND=$(ss -lnt 2>/dev/null | grep -c "127.0.0.1:$PORT " || true)
else
    BOUND=$(netstat -lnt 2>/dev/null | grep -c "127.0.0.1:$PORT " || true)
fi
if [ "$BOUND" = 0 ]; then
    say 'Служба пока не открыла порт; проверьте logread -e synet-balancer.'
    die 'Автоматически выбирать узел PassWall2 не будем.'
fi

say 'Создание локального узла PassWall2 (без выбора активным)...'
if command -v uci >/dev/null 2>&1; then
  existing=''
  for i in $(seq 0 99); do
    name=$(uci -q get "passwall2.@nodes[$i].remarks" 2>/dev/null || true)
    if [ "$name" = 'Synet eGames JSON (local)' ]; then
      existing="@nodes[$i]"
      break
    fi
  done
  if [ -z "$existing" ]; then
    id=$(uci add passwall2 nodes)
    uci set "passwall2.$id.remarks=Synet eGames JSON (local)"
    uci set "passwall2.$id.type=Xray"
    uci set "passwall2.$id.protocol=socks"
    uci set "passwall2.$id.address=127.0.0.1"
    uci set "passwall2.$id.port=$PORT"
    uci commit passwall2
    say 'Локальный SOCKS-узел добавлен; активный профиль и правила сохранены.'
  else
    say 'Локальный узел уже присутствует.'
  fi
fi

CRON='*/15 * * * * /usr/libexec/synet-balancer/update.sh >/dev/null 2>&1'
mkdir -p /etc/crontabs
touch /etc/crontabs/root
if ! grep -Fq '/usr/libexec/synet-balancer/update.sh' /etc/crontabs/root; then
  printf '%s\n' "$CRON" >> /etc/crontabs/root
fi
/etc/init.d/cron enable >/dev/null 2>&1 || true
/etc/init.d/cron restart >/dev/null 2>&1 || true

say "ГОТОВО: 127.0.0.1:19080 (SOCKS5), режим $MODE, обновление каждые 15 минут."
say 'В PassWall2 вручную выберите узел: Synet eGames JSON (local).'
say 'Прежде проверьте прокси: curl --socks5-hostname 127.0.0.1:19080 https://api.ipify.org'
say 'Если после выбора пропадёт интернет, верните прежний узел PassWall2.'