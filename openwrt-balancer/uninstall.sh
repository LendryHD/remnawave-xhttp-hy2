#!/bin/sh
# Remove local Synet OpenWrt balancer and PassWall2 (OpenWrt 24.10/opkg).
# Does not remove network, WAN, firewall, dnsmasq, curl, or shared dependencies.
set -u
[ "$(id -u)" = "0" ] || { echo 'Запустите от root'; exit 1; }
command -v opkg >/dev/null 2>&1 || { echo 'Нужен OpenWrt c opkg'; exit 1; }

echo '=== Удаление Synet Balancer и PassWall2 ==='
echo 'Место до удаления:'
df -h /overlay 2>/dev/null || true

# Stop user-space proxies before deleting the configuration and binaries.
for service in synet-balancer passwall2 passwall2_server; do
    if [ -x "/etc/init.d/$service" ]; then
        "/etc/init.d/$service" stop >/dev/null 2>&1 || true
        "/etc/init.d/$service" disable >/dev/null 2>&1 || true
    fi
done

# Delete only the cron entry owned by Synet, leaving all other jobs intact.
if [ -f /etc/crontabs/root ]; then
    sed -i '\|/usr/libexec/synet-balancer/update.sh|d' /etc/crontabs/root
fi

# Remove PassWall2 packages first: translations, application, any server subpackage.
packages=$(opkg list-installed | awk '$1 ~ /^luci-i18n-passwall2/ || $1 ~ /^luci-app-passwall2/ || $1 ~ /^passwall2($|-)/ {print $1}')
for pkg in $packages; do
    echo "Удаляю пакет: $pkg"
    opkg remove "$pkg" || echo "ПРЕДУПРЕЖДЕНИЕ: opkg не смог удалить $pkg"
done

# All paths below are dedicated to this integration or PassWall2, not shared system files.
rm -rf /etc/synet-balancer /usr/libexec/synet-balancer /tmp/synet-balancer
rm -f /etc/init.d/synet-balancer /tmp/synet.sh /tmp/synet-openwrt.sh /tmp/synet-openwrt-installer.sh
rm -f /tmp/synet-xray-check.*
rm -rf /etc/config/passwall2 /etc/config/passwall2_server /etc/passwall2 /usr/share/passwall2
rm -f /etc/init.d/passwall2 /etc/init.d/passwall2_server

# Large proxy binaries/data may also be used by Podkop, Nikki, HomeProxy etc.
# Preserve these automatically if another proxy manager is installed.
other_proxy=0
if [ -x /etc/init.d/podkop ] || [ -x /etc/init.d/homeproxy ] ||
   [ -x /etc/init.d/openclash ] || [ -x /etc/init.d/nikki ] ||
   opkg list-installed | grep -Eq '^(podkop|luci-app-podkop|homeproxy|luci-app-homeproxy|nikki|luci-app-nikki|luci-app-openclash|openclash|luci-app-passwall|luci-app-mihomo|mihomo) - '; then
    other_proxy=1
fi

if [ "$other_proxy" -eq 1 ]; then
    echo 'Есть другой прокси-клиент: sing-box и GeoIP оставлены, чтобы не нарушить его работу.'
else
    for pkg in sing-box xray-core geoview v2ray-geoip v2ray-geosite v2ray-geodata; do
        if opkg list-installed | grep -Fq "$pkg - "; then
            echo "Удаляю ненужный пакет: $pkg"
            opkg remove "$pkg" || echo "ПРЕДУПРЕЖДЕНИЕ: $pkg нужен другому пакету или не удалился"
        fi
    done
    # Remove only orphaned geodata after checking package ownership.
    if ! opkg list-installed | grep -Eq '^v2ray-(geoip|geosite|geodata) - '; then
        rm -f /usr/share/v2ray/geoip.dat /usr/share/v2ray/geosite.dat
    fi
fi

# Clear stale temporary runtime files; keep WAN/DNS and firewall configurations.
rm -rf /tmp/etc/passwall2 /tmp/run/passwall2 /tmp/log/passwall2
[ -x /etc/init.d/cron ] && /etc/init.d/cron restart >/dev/null 2>&1 || true
[ -x /etc/init.d/firewall ] && /etc/init.d/firewall restart >/dev/null 2>&1 || true
[ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true

echo
echo '=== Остатки пакетов PassWall2 ==='
opkg list-installed | grep -E '^(luci-app-passwall2|luci-i18n-passwall2|passwall2) - ' || echo 'Не найдены'
echo '=== Место после удаления ==='
df -h /overlay 2>/dev/null || true
echo 'Готово. GitHub-репозиторий не затронут.'
