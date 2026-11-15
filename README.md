# Remnawave XHTTP + Hysteria2 — дополнение к eGames

**Версия 0.2 (предварительная, необходим тест на отдельной VPS).** Дополнение для **уже установленных через eGames** Remnawave Node с Caddy. Настраивает XHTTP через Caddy и Hysteria2 (UDP/443), организует доставку TLS-сертификата с ноды на панель и *при настройке отдельного API-токена Remnawave* отправляет запрос на применение нового сертификата.

**Не заменяет eGames.** Не устанавливает Remnawave/NetBird, не меняет Caddy панели, MFA, домены подписок, REALITY и каскады. Не создаёт автоматически inbound/host в панели. Новую ноду сначала устанавливают штатным мастером eGames.

> **Безопасность:** пока установщик не проверен на отдельном тестовом VPS, не запускайте его на боевой ноде. Перед любыми изменениями сохраните резервные копии. Скрипт не содержит и не требует публикации закрытых ключей и токенов.

## 1. Архитектура и требования

```text
                         Remnawave Panel + NetBird
                         /opt/remnawave/xray-ssl/<domain>/
                                  ↑
                    SFTP отдельным непривилегированным пользователем
                                  ↑
Клиент HAPP → нода eGames Caddy + Xray
      VLESS REALITY → 443/TCP → Xray
      VLESS XHTTP   → 443/TCP → Caddy → /dev/shm/xrxh.socket
      Hysteria2     → 443/UDP → Xray (TLS от Caddy)
```

На **ноде**: Linux с systemd, Docker, `openssl`, `python3`, `ssh`, `scp`, `curl`, `flock`; уже развернуты `remnanode` и `caddy-remnawave` через eGames. DNS домена ноды должен вести на её публичный адрес. Caddy уже должен получить TLS-сертификат. На **панели**: Remnawave, `docker compose`, OpenSSH с `sftp-server` и доступный локально API `http://127.0.0.1:3000`. Если API размещён иначе, автоматический перезапуск не будет работать до отдельной адаптации; скрипт **не открывает API наружу**.

На панели должен быть постоянный bind mount для сертификатов (как уже настроено в текущем проекте):

```yaml
# /opt/remnawave/docker-compose.override.yml — добавьте, только если том отсутствует
services:
  remnawave:
    volumes:
      - type: bind
        source: /opt/remnawave/xray-ssl
        target: /var/lib/remnawave/configs/xray/ssl
        read_only: true
```

**Не перезаписывайте существующий `docker-compose.override.yml`.** При необходимости аккуратно дополните его, предварительно сохранив копию. Проверьте `cd /opt/remnawave && docker compose config` и примените `docker compose up -d --no-deps remnawave`. Не используйте `docker compose down`.

## 2. Загрузка установщика (на обеих VPS)

Загрузите на **каждую** машину, где нужно выполнять команду. Сначала просмотрите скрипт:

```bash
curl -fsSLo /root/remnawave-hy2-setup.sh \
  https://raw.githubusercontent.com/LendryHD/remnawave-xhttp-hy2/main/setup.sh
less /root/remnawave-hy2-setup.sh
bash -n /root/remnawave-hy2-setup.sh
```

Для воспроизводимого развёртывания рекомендуется заменить `main` в URL на проверенный SHA коммита.

## 3. Новая нода — одна команда после eGames

Сначала используйте eGames (`rr`) для установки ноды с Caddy и NetBird. Проверьте `https://node.example.com/` и TCP/443 REALITY. **На самой ноде:**

```bash
sudo bash /root/remnawave-hy2-setup.sh node node.example.com 203.0.113.10
```

Замените `node.example.com` на домен **этой ноды**, `203.0.113.10` — на публичный IP **сервера панели** (не ноды). Скрипт:

- сохранит резервную копию `/opt/remnanode/Caddyfile.bak.*` и добавит путь `/xhttppath/*` на `unix+h2c//dev/shm/xrxh.socket`, если он ещё отсутствует;
- проверит `caddy validate`, затем перезапустит **только Caddy ноды**; в случае неудачи восстановит копию;
- откроет `443/udp` через UFW, если он активен;
- создаст JSON-шаблон двух inbound в `/opt/remnawave-hy2/examples/node.example.com/inbounds.json`;
- создаст отдельную SSH-пару Ed25519 и `rw-hy2-push-node.example.com.timer` (проверка каждые 12 часов).

**Эта команда не завершает всю установку в панели:** SSH-ключ ещё надо разрешить на панели, а JSON/inbound/host добавить в интерфейсе по инструкциям ниже.

## 4. Уже работающая нода — безопасная миграция (Russia)

Если REALITY, XHTTP и Hysteria2 **уже работают** (как `ru.synet.pw`), нельзя повторно заменять Caddyfile. Используйте **только** режим `migrate` на российском VPS:

```bash
sudo bash /root/remnawave-hy2-setup.sh migrate ru.synet.pw 45.137.60.221
```

Скрипт проверит наличие контейнеров eGames, XHTTP-маршрута, сокета и UDP/443. После этого установит только **таймер и SSH-ключ синхронизации**. **Никаких изменений Caddyfile, Xray JSON, inbound, MFA или NetBird не происходит.** В конце выводится публичный ключ вида `ssh-ed25519 AAAA... hy2-sync-ru.synet.pw`.

Скопируйте **только публичную строку**. Приватный ключ остаётся на российском сервере в `/opt/remnawave-hy2/keys/`.

## 5. Подключение передачи сертификата на панели

На **сервере панели** загрузите тот же `setup.sh` и введите публичный ключ, полученный при `node`/`migrate`:

```bash
sudo bash /root/remnawave-hy2-setup.sh panel \
  ru.synet.pw 168.113.156.10 \
  'ssh-ed25519 AAAA... hy2-sync-ru.synet.pw'
```

Для других нод замените домен и публичный адрес сервера. `panel` создаёт **отдельного непривилегированного пользователя** `rw-hy2-upload` (без sudo, с отключённым входом по паролю). Публичный ключ добавляется только с указанного IP, с `restrict` и принудительной командой `sftp-server`. Это **не** ключ и не пользователь `lendry` для управления сервером.

Каталог приёма: `/var/lib/remnawave-hy2-upload/incoming/<domain>/`. Таймер панели: `rw-hy2-panel-sync.timer` (каждые 30 минут). Целевые сертификаты: `/opt/remnawave/xray-ssl/<domain>/`.

### Проверка отпечатка SSH сервера панели

**На панели** получите известный отпечаток:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

**На ноде** получите ключ, сверьте отпечаток вручную с выводом на панели и **только после совпадения** добавьте ключ в `known_hosts`:

```bash
ssh-keyscan -t ed25519 45.137.60.221 > /tmp/verified-panel-hostkey
ssh-keygen -lf /tmp/verified-panel-hostkey
# СРАВНИТЬ с отпечатком с панели, затем:
install -d -m 700 /root/.ssh
cat /tmp/verified-panel-hostkey >> /root/.ssh/known_hosts
chmod 600 /root/.ssh/known_hosts
rm -f /tmp/verified-panel-hostkey
```

Теперь **на ноде** запустите первое копирование, **на панели** — первый импорт:

```bash
# на НОДЕ
sudo /opt/remnawave-hy2/setup.sh node-sync ru.synet.pw 45.137.60.221

# на ПАНЕЛИ
sudo /opt/remnawave-hy2/setup.sh panel-sync
sudo ls -l /opt/remnawave/xray-ssl/ru.synet.pw/
```

Скрипт проверяет домен, срок действия (не менее 7 дней) и совпадение открытого ключа сертификата с закрытым. Если пара некорректна, обновление не применяется. Если новый сертификат принят, появляется маркер `/opt/remnawave-hy2/state/ru.synet.pw.needs-apply` до запроса на его применение.

> **Примечание:** принудительный SFTP с отдельным пользователем ещё не тестировался в живой конфигурации. Если `scp` выдаст ошибку, смотрите `journalctl -u ssh` на панели; не ослабляйте настройки `sshd` и не переключайтесь на `root`/`lendry` для таймера.

## 6. API-токен вводится через сам скрипт — без хардкода

**Создавайте токен в веб-панели Remnawave**, а не в NetBird и не в Caddy MFA. Откройте Remnawave → **Настройки → API-токены**, выпустите отдельный токен для управления нодами. Запишите **UUID нужной ноды** в разделе «Ноды → Russia». Право токена должно позволять чтение ноды и её перезапуск; не используйте личные пароли. Для версии с областями доступа проверьте `nodes:read` и `nodes:write`.

**На финском VPS панели** выполните:

```bash
sudo /opt/remnawave-hy2/setup.sh api-setup \
  ru.synet.pw UUID-НОДЫ-RUSSIA
```

Скрипт попросит токен **в интерактивном терминале со скрытым вводом**. Токен **не является аргументом команды**, не вставляется в URL, `.env`, Compose или GitHub. При проверке он передаётся запросом к локальному `127.0.0.1:3000` через заголовок `Authorization: Bearer` и локальный временный файл `0600` (без секретов в аргументах `curl`). При HTTP 200 сохраняется в:

```text
/etc/remnawave-hy2/node-ru.synet.pw.token   # root:root, 0600
/etc/remnawave-hy2/node-ru.synet.pw.meta    # UUID, 0600
```

Если API не принимает токен или не видит ноду, скрипт не сохраняет новый токен и не перезапускает ничего. Проверка и удаление локальной копии:

```bash
sudo /opt/remnawave-hy2/setup.sh api-test ru.synet.pw
sudo /opt/remnawave-hy2/setup.sh api-delete ru.synet.pw
```

`api-delete` удаляет **только локальные файлы**. Для полного отзыва ключа удалите/отзовите его и в веб-панели Remnawave.

**Важно о двух уровнях авторизации:** `Authorization: Bearer` — токен самой Remnawave (используется нашим локальным скриптом). `X-Api-Key` — ключ портала Caddy MFA для **внешних** запросов через Caddy; он здесь не требуется и не сохраняется. NetBird API — третий, независимый токен. Подробнее: [Remnawave SDK](https://docs.rw/sdk/typescript-sdk/) и [eGames — внешний API](https://wiki.egam.es/configuration/external-api/).

## 7. Автоматическое применение нового сертификата

`panel-sync` сравнивает сертификаты и копирует новую проверенную пару в bind mount панели. Если файлы изменились, он отмечает `needs-apply` и пытается вызвать **только для UUID выбранной ноды**:

```http
POST http://127.0.0.1:3000/api/nodes/<UUID>/actions/restart
Authorization: Bearer <ТОКЕН_ИЗ_ФАЙЛА>
Content-Type: application/json

{"forceRestart":true}
```

При HTTP 200/202/204 маркер запроса удаляется; в журнале сохраняется только статус и домен, **не сам токен**. Это подтверждает принятие запроса API, **не гарантирует** уже завершённый перезапуск и появление нового TLS-сертификата у клиентов. Обязательно проверяйте HAPP и состояние ноды после первого применения. Если API недоступен, маркер остаётся, таймер повторит попытку; ручной вариант — `Ноды → Russia → Force Restart`.

Проверки:

```bash
# На панели
systemctl status rw-hy2-panel-sync.timer --no-pager
journalctl -u rw-hy2-panel-sync.service -n 30 --no-pager

# На ноде
systemctl status rw-hy2-push-ru.synet.pw.timer --no-pager
journalctl -u rw-hy2-push-ru.synet.pw.service -n 30 --no-pager
```

**Сертификат автоматически продлевает Caddy ноды.** Нода передаёт его на панель каждые 12 часов, панель импортирует каждые 30 минут. Без действующего API-токена доставка остаётся автоматической, но применение — ручным.

## 8. Добавление inbound и хостов в Remnawave (для НОВОЙ ноды)

**Не нужно выполнять этот раздел при миграции Russia**, если два inbound и два хоста уже работают.

На панели Remnawave откройте «Конфигурационные профили» → нужный профиль. Сохраните резервную копию JSON. Из файла на ноде `/opt/remnawave-hy2/examples/<domain>/inbounds.json` добавьте **два объекта внутрь существующего массива `inbounds`** (не вставляйте вложенный массив). Не изменяйте исходный REALITY inbound.

| Параметр | VLESS XHTTP | Hysteria2 |
|---|---|---|
| Tag | `<domain>-XHTTP` | `<domain>-HY2` |
| Протокол | `vless` | `hysteria`, version 2 |
| Внешний порт | TCP 443 через Caddy | UDP 443 |
| Listen | `/dev/shm/xrxh.socket,0666` | `0.0.0.0:443` |
| Network | `xhttp` | `hysteria` |
| Security inbound | `none` (TLS завершается в Caddy) | `tls` |
| Дополнительно | `mode=auto`, `path=/xhttppath/` | ALPN `h3`, BBR |
| TLS файлы | не требуются в inbound | `/var/lib/remnawave/configs/xray/ssl/<domain>/` |

В «Ноды → Управление → нужная нода → Профили» выберите старый REALITY и два новых inbound, **сохраните**. При необходимости выполните `Force Restart` только этой ноды, как делали с Russia при первоначальном внедрении XHTTP.

Создайте два хоста для подписок:

| Поле хоста | XHTTP | HY2 |
|---|---|---|
| Название | `Node XHTTP` | `Node Hysteria2` |
| Inbound | `<domain>-XHTTP` | `<domain>-HY2` |
| Address | `node.example.com` | `node.example.com` |
| Port | 443 | 443 |
| Security | `tls` (публичное) | `tls` |
| SNI | `node.example.com` | `node.example.com` |
| ALPN | `h2` | `h3` |
| Path | `/xhttppath/` | пусто |
| Mode | `auto` | — |
| Flow | пусто | — |
| Allow insecure | выкл. | выкл. |

Сохраните хосты, убедитесь, что они доступны нужной группе пользователей, обновите подписку в HAPP и по очереди проверьте внешний IP через каждое подключение. **Caddy панели и страницу подписок не меняйте.**

## 9. Удаление старого временного SSH-ключа после миграции Russia

**Только после успешного `node-sync`, `panel-sync` и проверки Hysteria2**. Старый ключ `hy2-transfer-temp`, созданный при ручном копировании сертификата, больше не нужен. На **панели**:

```bash
sudo /opt/remnawave-hy2/setup.sh cleanup-legacy-panel ru.synet.pw
```

Скрипт найдёт только строки с пометкой `hy2-transfer-temp` в `/home/lendry/.ssh/authorized_keys`, попросит явное подтверждение `yes`, сохранит резервную копию файла и удалит эти строки. Не затрагивает другие ключи.

На **российской ноде**:

```bash
sudo /opt/remnawave-hy2/setup.sh cleanup-legacy-node ru.synet.pw
```

После подтверждения будет удалён только `/root/.ssh/hy2-transfer-key` и соответствующий `.pub`. Обычные SSH-ключи не затрагиваются. Старые временные копии сертификатов удаляйте отдельно после проверки, что они нигде не используются.

## 10. Диагностика и откат

```bash
# На ноде
sudo /opt/remnawave-hy2/setup.sh status ru.synet.pw
ss -lunp | grep ':443'              # UDP/443 Hysteria2
ss -lntp | grep ':443'              # TCP/443 REALITY
ls -l /dev/shm/xrxh.socket          # XHTTP
curl --http2 -I https://ru.synet.pw/

# На панели
sudo /opt/remnawave-hy2/setup.sh api-test ru.synet.pw
sudo /opt/remnawave-hy2/setup.sh panel-sync
```

- `Permission denied (publickey)` — проверьте зарегистрированный публичный ключ, IP-источник, отпечаток панели, отдельного SFTP-пользователя; не включайте root SSH и парольный вход.
- Сертификат устарел — посмотрите `node-sync`, срок TLS в Caddy, журналы обоих таймеров и маркер `.needs-apply`.
- API 401/403 — токен неверен, истёк или недостаточно прав, проверьте настройки Remnawave. Не используйте токен Caddy MFA вместо Remnawave.
- Нет XHTTP-сокета — проверьте, что inbound выбран для ноды; затем штатный Force Restart только этой ноды.
- Caddy `502` на `/xhttppath/` — проверьте `/dev/shm/xrxh.socket` и доступ из контейнера Caddy.
- Для отката Caddy **новой ноды** найдите сохранённый `/opt/remnanode/Caddyfile.bak.*`, восстановите нужный, проверьте `caddy validate` и перезапустите только Caddy ноды. Не удаляйте REALITY.

## 11. Безопасность, ограничения и источники

- Не публикуйте приватный ключ REALITY, TLS `privkey.key`, `.token`, SSH-приватные ключи, `SECRET_KEY`, UUID+токен вместе, подписки пользователей или полный `dump-config`.
- `migrate` не изменяет работающие VPN-протоколы, но может создать ключ и systemd-таймер. API-ключ можно ввести только на **панели**, он никогда не нужен на ноде.
- Скрипт имеет право рестартовать **только выбранную ноду**, если вы сами настроили API и пришёл новый сертификат. Первое реальное применение нужно проверить вручную.
- Транспорт SFTP не переправляет пользовательский VPN-трафик; он служит только для передачи сертификата. Не используйте его для каскадов.
- Встроенный тест `bash tests/check.sh` проверяет синтаксис, TLS-пару и скрытую передачу API-токена на mock-клиенте. Он **не заменяет** тест развертывания на тестовой VPS.

Документация: [Remnawave API](https://docs.rw/api/), [Remnawave SDK](https://docs.rw/sdk/typescript-sdk/), [eGames](https://wiki.egam.es/ru/), [Caddy reverse_proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy), [Remnawave Node TLS](https://docs.rw/install/remnawave-node/).

Лицензия: MIT. Это неофициальное дополнение, не часть Remnawave/eGames.