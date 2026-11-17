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

say '=== Synet v0.4: Remnawave Xray JSON → локальный SOCKS5 → PassWall2 ==='
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
        say 'RAM-режим: Xray будет загружен в /tmp, без установки во flash.'
        say 'После перезагрузки загрузка Xray повторится автоматически.'
    fi
fi
need=''
command -v jq >/dev/null 2>&1 || need="$need jq"
if [ "$MODE" = ram ]; then
    command -v unzip >/dev/null 2>&1 || need="$need unzip"
fi
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
# Prefer official Xray release (HY2 support), falling back to signed OpenWrt feed.
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
    rm -f "$RUNTIME/xray-new" "$RUNTIME/xray.zip" "$RUNTIME/xray.zip.dgst" "$RUNTIME"/xray-core_*.ipk
    rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
free_tmp=$(df -Pk /tmp | awk 'NR==2 {print $4}')
free_mem=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
[ "$free_tmp" -ge 55000 ] || { echo 'В /tmp недостаточно свободного места' >&2; exit 1; }
[ "$free_mem" -ge 75000 ] || { echo 'Недостаточно RAM для запуска Xray' >&2; exit 1; }
cd "$RUNTIME"
# v26.11.9 includes Hysteria2 support; the older OpenWrt feed may not.
ZIP_URL='https://github.com/XTLS/Xray-core/releases/download/v26.11.9/Xray-linux-arm64-v8a.zip'
if curl -fsSL --connect-timeout 10 --max-time 180 --retry 1 -o "$RUNTIME/xray.zip" "$ZIP_URL" &&
   curl -fsSL --connect-timeout 10 --max-time 30 --retry 1 -o "$RUNTIME/xray.zip.dgst" "$ZIP_URL.dgst"; then
    expected=$(awk -F '= ' '/256=/ {print $2; exit}' "$RUNTIME/xray.zip.dgst" | tr -d '\r')
    actual=$(sha256sum "$RUNTIME/xray.zip" | awk '{print $1}')
    [ -n "$expected" ] && [ "$actual" = "$expected" ] || {
        echo 'SHA256 официального архива не совпал: загрузка отменена.' >&2
        exit 1
    }
    if unzip -p "$RUNTIME/xray.zip" xray > "$RUNTIME/xray-new"; then
        chmod 700 "$RUNTIME/xray-new"
        if "$RUNTIME/xray-new" version >/dev/null 2>&1; then
            mv "$RUNTIME/xray-new" "$RUNTIME/xray"
            echo 'Xray v26.11.9 загружен и проверен в /tmp.'
            exit 0
        fi
    fi
    echo 'Не удалось запустить официальный ARM64 Xray; попробую пакет OpenWrt.' >&2
else
    echo 'GitHub Releases недоступен; попробую пакет из feed OpenWrt.' >&2
fi
rm -f "$RUNTIME/xray.zip" "$RUNTIME/xray.zip.dgst" "$RUNTIME/xray-new"
# Fallback: OpenWrt 24.10 .ipk is a tar.gz containing data.tar.gz.
# This feed may have an old core without Hysteria2 support.
opkg update >/dev/null || { echo 'Не удалось обновить подписанные пакеты OpenWrt' >&2; exit 1; }
rm -f xray-core_*.ipk
opkg download xray-core >/dev/null || { echo 'Не удалось скачать xray-core' >&2; exit 1; }
pkg=$(find "$RUNTIME" -maxdepth 1 -name 'xray-core_*.ipk' -type f | head -1)
[ -n "$pkg" ] && [ -s "$pkg" ] || { echo 'Пакет xray-core не найден' >&2; exit 1; }
if ! (tar -xOzf "$pkg" ./data.tar.gz | tar -xOzf - ./usr/bin/xray) > "$RUNTIME/xray-new"; then
    echo 'Не удалось извлечь Xray из пакета' >&2
    exit 1
fi
[ -s "$RUNTIME/xray-new" ] || exit 1
chmod 700 "$RUNTIME/xray-new"
"$RUNTIME/xray-new" version >/dev/null 2>&1 || { echo 'Xray не исполняется на этом CPU' >&2; exit 1; }
mv "$RUNTIME/xray-new" "$RUNTIME/xray"
echo 'Xray из feed OpenWrt размещён в RAM; Hysteria2 может быть недоступна.'
ENSURE
chmod 700 "$LIB/ensure-xray.sh"

cat > "$LIB/serve.sh" <<'SERVE'
#!/bin/sh
set -eu
BASE=/etc/synet-balancer
LIB=/usr/libexec/synet-balancer
[ -f /usr/share/v2ray/geoip.dat ] && export XRAY_LOCATION_ASSET=/usr/share/v2ray
while ! "$LIB/ensure-xray.sh"; do
    echo 'Synet: повтор загрузки Xray через 30 секунд' >&2
    sleep 30
done
if [ "$(cat "$BASE/mode")" = ram ]; then
    exec /tmp/synet-balancer/xray run -format json -c "$BASE/active.json"
fi
exec "$(command -v xray)" run -format json -c "$BASE/active.json"
SERVE
chmod 700 "$LIB/serve.sh"

cat > "$LIB/merge.jq" <<'SYNET_MERGE_JQ'
# Merge 1–2 eGames Xray JSON subscriptions into ONE Xray process.
# Port 19080 is for profile #1, 19081 for profile #2.
# All outbound and balancer tags are namespaced, routing stays per-inbound.
def pref($p): if type == "string" then $p + . else . end;
def transform_outbound($p):
  .tag |= pref($p)
  | if (.proxySettings.tag? | type) == "string" then .proxySettings.tag |= pref($p) else . end
  | if (.streamSettings.sockopt.dialerProxy? | type) == "string" then .streamSettings.sockopt.dialerProxy |= pref($p) else . end;
def transform_balancer($p):
  .tag |= pref($p)
  | .selector |= map(pref($p))
  | if (.fallbackTag? | type) == "string" then .fallbackTag |= pref($p) else . end;
def transform_rule($p; $in):
  .inboundTag = [$in]
  | if (.outboundTag? | type) == "string" then .outboundTag |= pref($p) else . end
  | if (.balancerTag? | type) == "string" then .balancerTag |= pref($p) else . end;

(if type == "object" then [.] elif type == "array" then . else error("Expected Xray JSON object or array") end) as $configs
| if ($configs | length) < 1 or ($configs | length) > 2 then
    error("Expected 1 or 2 JSON profiles")
  elif ($configs | all(.[]; type == "object" and (.outbounds | type) == "array" and (.routing.balancers | type) == "array" and (.routing.balancers | length) > 0 and (.routing.rules | type) == "array" and (.burstObservatory.subjectSelector | type) == "array")) | not then
    error("Every profile must contain outbounds, routing.balancers, routing.rules and burstObservatory")
  elif ($configs | any(.[]; ((.outbounds | map(.tag) | unique | length) != (.outbounds | length)))) then
    error("Duplicate outbound tags in a profile")
  elif ($configs | map(.burstObservatory.pingConfig) | unique | length) != 1 then
    error("Different burstObservatory pingConfig values; cannot combine safely")
  elif ($configs | map(.dns) | unique | length) != 1 then
    error("Different DNS configurations; cannot combine safely")
  elif ($configs | map(.routing | del(.rules, .balancers)) | unique | length) != 1 then
    error("Different global routing options; cannot combine safely")
  else
    ($configs | to_entries | map(
      .key as $idx | .value as $c
      | ("synet-" + (($idx + 1) | tostring) + "-") as $p
      | ("synet-" + (($idx + 1) | tostring) + "-in") as $in
      | ($port + $idx) as $listen_port
      | {
          inlet: {"tag": $in, "listen":"127.0.0.1", "port": $listen_port, "protocol":"socks", "settings":{"udp":true,"auth":"noauth"}},
          outbounds: ($c.outbounds | map(transform_outbound($p))),
          balancers: ($c.routing.balancers | map(transform_balancer($p))),
          rules: ($c.routing.rules | map(transform_rule($p; $in))),
          selectors: ($c.burstObservatory.subjectSelector | map(pref($p)))
        }
    )) as $parts
    | ($configs[0] | {dns,log,policy}) as $opts
    | $opts + {
        inbounds: [$parts[].inlet],
        outbounds: [$parts[].outbounds[]],
        routing: (($configs[0].routing | del(.balancers, .rules)) + {
          balancers: [$parts[].balancers[]],
          rules: [$parts[].rules[]]
        }),
        burstObservatory: ($configs[0].burstObservatory + {
          subjectSelector: ([$parts[].selectors[]] | unique)
        })
      }
  end
SYNET_MERGE_JQ
chmod 600 "$LIB/merge.jq"

cat > "$LIB/update.sh" <<'UPDATE'
#!/bin/sh
set -eu
umask 077
BASE=/etc/synet-balancer
LIB=/usr/libexec/synet-balancer
[ -f /usr/share/v2ray/geoip.dat ] && export XRAY_LOCATION_ASSET=/usr/share/v2ray
PORT=$(cat "$BASE/port")
TEMP=$(mktemp "$BASE/download.XXXXXX")
CFG=$(mktemp "$BASE/checked.XXXXXX")
# Xray infers configuration format from filename; BusyBox mktemp has no .json suffix.
mv "$CFG" "$CFG.json"
CFG="$CFG.json"
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
if ! jq -e --argjson port "$PORT" -f "$LIB/merge.jq" "$TEMP" > "$CFG" 2>/dev/null; then
    echo 'Формат не поддержан: ожидается один полный Xray JSON с routing.balancers.' >&2
    echo 'Структура ответа (только имена полей, без токенов и конфигураций):' >&2
    jq -r '
      if type == "object" then
        "JSON: object; поля: " + (keys | join(", ")) +
        "; outbounds: " + (if (.outbounds | type) == "array" then (.outbounds | length | tostring) else "-" end) +
        "; routing.balancers: " + (if (.routing.balancers | type) == "array" then (.routing.balancers | length | tostring) else "-" end) +
        "; routing-поля: " + (if (.routing | type) == "object" then (.routing | keys | join(", ")) else "-" end)
      elif type == "array" then
        "JSON: array; элементов: " + (length | tostring) +
        "; первый элемент: " + (if length > 0 then (.[0] | type) else "-" end) +
        "; поля первого: " + (if length > 0 and (.[0] | type) == "object" then (.[0] | keys | join(", ")) else "-" end)
      else "JSON: " + type end
    ' "$TEMP" 2>/dev/null >&2 || echo 'Ответ не разобран как JSON.' >&2
    echo 'Ни одна конфигурация не применена; PassWall2 не изменён.' >&2
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
VALIDATION_LOG=$(mktemp /tmp/synet-xray-check.XXXXXX)
chmod 600 "$VALIDATION_LOG"
if ! "$XRAY" run -test -format json -c "$CFG" >"$VALIDATION_LOG" 2>&1; then
    echo 'Xray отклонил JSON; конфигурация не применена.' >&2
    echo 'Версия ядра:' >&2
    "$XRAY" version 2>/dev/null | head -n 1 >&2 || true
    echo 'Последние строки диагностики Xray (перед отправкой проверьте отсутствие секретов):' >&2
    tail -n 12 "$VALIDATION_LOG" >&2
    rm -f "$VALIDATION_LOG"
    exit 1
fi
rm -f "$VALIDATION_LOG"
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
    count=$(jq -r '.inbounds | length' "$BASE/active.json")
    i=0
    while [ "$i" -lt "$count" ]; do
        current_port=$((PORT + i))
        if command -v ss >/dev/null 2>&1; then
            bound=$(ss -lnt | grep -c "127.0.0.1:$current_port " || true)
        else
            bound=$(netstat -lnt 2>/dev/null | grep -c "127.0.0.1:$current_port " || true)
        fi
        if [ "$bound" = 0 ]; then
            if [ -f "$BASE/previous.json" ]; then
                cp "$BASE/previous.json" "$BASE/active.json"
                /etc/init.d/synet-balancer restart >/dev/null 2>&1 || true
            fi
            echo "SOCKS-порт $current_port не открылся; возвращена предыдущая конфигурация (если была)." >&2
            exit 1
        fi
        i=$((i + 1))
    done
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
EXPECTED=$(jq -r '.inbounds | length' "$BASE/active.json")
idx=0
while [ "$idx" -lt "$EXPECTED" ]; do
    current_port=$((PORT + idx))
    if command -v ss >/dev/null 2>&1; then
        BOUND=$(ss -lnt 2>/dev/null | grep -c "127.0.0.1:$current_port " || true)
    else
        BOUND=$(netstat -lnt 2>/dev/null | grep -c "127.0.0.1:$current_port " || true)
    fi
    if [ "$BOUND" = 0 ]; then
        die "SOCKS-порт $current_port не открылся. Выбранный узел PassWall2 не изменён."
    fi
    idx=$((idx + 1))
done

say 'Создание локальных SOCKS-узлов PassWall2 (без выбора активными)...'
if command -v uci >/dev/null 2>&1; then
  idx=0
  while [ "$idx" -lt "$EXPECTED" ]; do
    current_port=$((PORT + idx))
    nr=$((idx + 1))
    remark="Synet eGames $nr (local)"
    existing=''
    for i in $(seq 0 99); do
      name=$(uci -q get "passwall2.@nodes[$i].remarks" 2>/dev/null || true)
      if [ "$name" = "$remark" ]; then
        existing="@nodes[$i]"
        break
      fi
    done
    if [ -z "$existing" ]; then
      id=$(uci add passwall2 nodes)
      uci set "passwall2.$id.remarks=$remark"
      uci set "passwall2.$id.type=sing-box"
      uci set "passwall2.$id.protocol=socks"
      uci set "passwall2.$id.address=127.0.0.1"
      uci set "passwall2.$id.port=$current_port"
      say "Добавлен локальный узел: $remark, порт $current_port"
    else
      say "Узел уже существует: $remark"
    fi
    idx=$((idx + 1))
  done
  uci commit passwall2
fi

CRON='*/15 * * * * /usr/libexec/synet-balancer/update.sh >/dev/null 2>&1'
mkdir -p /etc/crontabs
touch /etc/crontabs/root
if ! grep -Fq '/usr/libexec/synet-balancer/update.sh' /etc/crontabs/root; then
  printf '%s\n' "$CRON" >> /etc/crontabs/root
fi
/etc/init.d/cron enable >/dev/null 2>&1 || true
/etc/init.d/cron restart >/dev/null 2>&1 || true

if [ "$EXPECTED" -eq 2 ]; then
    say "ГОТОВО: два балансировщика через 127.0.0.1:19080 и :19081; режим $MODE."
else
    say "ГОТОВО: балансировщик через 127.0.0.1:19080; режим $MODE."
fi
say 'Автообновление — раз в 15 минут; текущие маршруты PassWall2 не переключены.'
say 'В PassWall2 вручную выберите Synet eGames 1 (local) или Synet eGames 2 (local).'
say 'Проверка: curl --socks5-hostname 127.0.0.1:19080 https://api.ipify.org'
say 'Если после выбора пропадёт интернет, верните прежний узел PassWall2.'