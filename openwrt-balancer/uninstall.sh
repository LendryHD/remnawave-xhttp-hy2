#!/bin/sh
# Remove Synet Balancer, PassWall2 and Podkop from OpenWrt 24.10 (opkg).
# Shared system network, DNS, firewall and VPN interfaces are NOT wiped.
set -u

[ "$(id -u)" = 0 ] || { echo 'Запустите от root'; exit 1; }
command -v opkg >/dev/null 2>&1 || { echo 'Для этого скрипта требуется opkg'; exit 1; }

echo '=== Удаление PassWall2 + Podkop + Synet Balancer ==='
echo 'Свободное место до:'
df -h /overlay 2>/dev/null || true

# Stop before package removal so stale routing and DNS redirects can be released.
for service in synet-balancer passwall2 passwall2_server podkop; do
    if [ -x "/etc/init.d/$service" ]; then
        echo "Останавливаю: $service"
        "/etc/init.d/$service" stop || true
        "/etc/init.d/$service" disable || true
    fi
done

# Remove only the scheduled task created by our own Synet installer.
if [ -f /etc/crontabs/root ]; then
    sed -i '\|/usr/libexec/synet-balancer/update.sh|d' /etc/crontabs/root
fi

# Use package manager instead of force-delete. Do dependencies first.
# First remove translations and addons that depend on their main LuCI package.
remove_regex() {
    pattern="$1"
    installed=$(opkg list-installed | awk -v re="$pattern" '$1 ~ re {print $1}')
    for pkg in $installed; do
        echo "Удаляю: $pkg"
        if ! opkg remove "$pkg"; then
            echo "ПРЕДУПРЕЖДЕНИЕ: $pkg не удалён (проверьте зависимости)"
        fi
    done
}

# Two passes allow dependents and addons to be removed without --force-depends.
for pass in 1 2; do
    remove_regex '^luci-i18n-(passwall2|podkop)(-|$)'
    remove_regex '^luci-app-(passwall2|podkop)-'
    remove_regex '^luci-app-(passwall2|podkop)$'
    remove_regex '^(passwall2|podkop)-'
    remove_regex '^(passwall2|podkop)$'
done

# Always delete the integration's own files.
rm -rf /etc/synet-balancer /usr/libexec/synet-balancer /tmp/synet-balancer
rm -f /etc/init.d/synet-balancer /tmp/synet.sh /tmp/synet-openwrt.sh
rm -f /tmp/synet-openwrt-installer.sh /tmp/synet-xray-check.*

# Clean dedicated configuration only if all related packages are gone.
remaining_p2=$(opkg list-installed | awk '$1 ~ /^(luci-i18n-passwall2|luci-app-passwall2|passwall2)(-|$)/ {print $1}')
remaining_pk=$(opkg list-installed | awk '$1 ~ /^(luci-i18n-podkop|luci-app-podkop|podkop)(-|$)/ {print $1}')

if [ -z "$remaining_p2" ]; then
    rm -rf /etc/config/passwall2 /etc/config/passwall2_server /etc/passwall2 /usr/share/passwall2
    rm -rf /tmp/etc/passwall2 /tmp/run/passwall2 /tmp/log/passwall2
    rm -f /etc/init.d/passwall2 /etc/init.d/passwall2_server
else
    echo "ВНИМАНИЕ: PassWall2 ещё установлен: $remaining_p2"
fi
if [ -z "$remaining_pk" ]; then
    rm -rf /etc/config/podkop /etc/podkop /usr/share/podkop /usr/libexec/podkop
    rm -rf /tmp/podkop /tmp/etc/podkop /tmp/run/podkop /tmp/log/podkop
    rm -f /etc/init.d/podkop
else
    echo "ВНИМАНИЕ: Podkop ещё установлен: $remaining_pk"
fi

# Remove heavyweight components when none of the other proxy managers
# appear installed. opkg will refuse removal if still required by a package.
# Do NOT delete raw geoip.dat/geosite.dat files behind the package manager.
other_proxy=0
if [ -n "$remaining_p2$remaining_pk" ] ||
   opkg list-installed | awk '{print $1}' | grep -Eq '^(luci-app-passwall|luci-app-homeproxy|homeproxy|luci-app-nikki|nikki|luci-app-openclash|openclash|luci-app-ssr-plus|luci-app-v2raya|v2raya|luci-app-mihomo|mihomo)(-|$)' ||
   [ -x /etc/init.d/homeproxy ] || [ -x /etc/init.d/nikki ] || [ -x /etc/init.d/openclash ]; then
    other_proxy=1
fi

if [ "$other_proxy" -eq 0 ]; then
    echo 'Другие прокси-клиенты не обнаружены. Удаляю больше не нужные ядра и базы...'
    for pkg in sing-box xray-core geoview v2ray-geoip v2ray-geosite v2ray-geodata; do
        if opkg list-installed | awk '{print $1}' | grep -Fxq "$pkg"; then
            echo "Удаляю: $pkg"
            opkg remove "$pkg" || echo "ПРЕДУПРЕЖДЕНИЕ: $pkg остался (зависимости)"
        fi
    done
else
    echo 'Другой прокси-клиент или остаток PassWall2/Podkop обнаружен: общие sing-box и GeoIP сохранены.'
fi

[ -x /etc/init.d/cron ] && /etc/init.d/cron restart >/dev/null 2>&1 || true
[ -x /etc/init.d/firewall ] && /etc/init.d/firewall restart >/dev/null 2>&1 || true
[ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true

echo
echo '=== Остались пакеты ==='
opkg list-installed | awk '$1 ~ /^(luci-i18n-passwall2|luci-app-passwall2|passwall2|luci-i18n-podkop|luci-app-podkop|podkop)(-|$)/ {print $1}' | while read -r pkg; do
    echo "ОСТАЛСЯ: $pkg"
done
echo '=== Свободное место после ==='
df -h /overlay 2>/dev/null || true
echo 'Готово. Настройки WAN, LAN, DNS-серверов и исходный GitHub-репозиторий не менялись.'
