# Remnawave XHTTP + Hysteria2 — дополнение к eGames

Русскоязычный комплект для **уже установленных через eGames** нод Remnawave с Caddy. Настраивает путь **VLESS XHTTP через Unix-сокет Caddy** и **Hysteria2 на UDP/443**. Сохраняет существующий VLESS REALITY, NetBird, Caddy панели, MFA и подписки.

> **Статус: предварительный выпуск.** Логика подготовлена и проверена синтаксически; полный тест на отдельном тестовом VPS ещё не выполнен. Не запускайте без резервных копий на критичных серверах. Автоматизированное изменение профиля/хостов панели сознательно не реализовано: оно зависит от схемы конкретного Remnawave и должно выполняться по шагам ниже.

## Содержание

1. [Как устроена схема](#как-устроена-схема)
2. [Что делает и не делает скрипт](#что-делает-и-не-делает-скрипт)
3. [Подготовка](#подготовка)
4. [Установка дополнения на ноду](#установка-дополнения-на-ноду)
5. [Разрешение передачи сертификата на панели](#разрешение-передачи-сертификата-на-панели)
6. [Конфигурационный профиль Remnawave](#конфигурационный-профиль-remnawave)
7. [Настройка хостов в панели](#настройка-хостов-в-панели)
8. [Автоматическое обновление сертификата](#автоматическое-обновление-сертификата)
9. [Проверки, ошибки и откат](#проверки-ошибки-и-откат)
10. [Добавление следующей ноды](#добавление-следующей-ноды)
11. [Безопасность](#безопасность)

## Как устроена схема

```text
                          Remnawave Panel (Finland)
                          + NetBird management
                          + /opt/remnawave/xray-ssl/<domain>/
                          + systemd panel-sync timer
                              ^         |
      SFTP, отдельный SSH-ключ|         | профиль + сертификат
                              |         v
Клиент HAPP -> TCP/443 REALITY -> Node Xray (порт 443 TCP)
            -> TCP/443 XHTTP   -> Caddy -> unix+h2c -> Xray XHTTP socket
            -> UDP/443 HY2    -> Node Xray QUIC + TLS

На ноде: Caddy владеет сертификатом, node-sync timer отправляет копию на панель.
На панели: panel-sync timer проверяет сертификат и обновляет файлы.
При наличии API-токена панель инициирует Force Restart конкретной ноды.
```

**Важное ограничение:** один скрипт не создаёт саму ноду в панели и не подключает NetBird. Это выполняет eGames. После этого скрипт конфигурирует XHTTP/HY2. При первоначальной привязке *каждой* новой ноды нужно разрешить её SSH-ключ на панели; без заранее выданного права доступа безопасная полностью автономная установка невозможна.

## Что делает и не делает скрипт

**Делает:** резервную копию Caddyfile ноды; добавляет `handle /xhttppath/*` с `reverse_proxy unix+h2c//dev/shm/xrxh.socket` (если маршрута ещё нет); проверяет конфигурацию Caddy и перезапускает **только Caddy ноды**; открывает UDP/443, если активен UFW; генерирует пример двух новых inbound; устанавливает таймер копирования сертификата Caddy; на панели создаёт защищённый каталог и таймер приёма; при наличии официального API-токена Remnawave может запустить Force Restart выбранной ноды после обновления сертификата.

**Не делает:** не устанавливает Docker, eGames, Remnawave, NetBird; не изменяет REALITY или Caddy панели; не меняет SSH-порт; не настраивает каскады; не создаёт пользователей/хосты/профили через API; не отключает NetBird Default.

## Подготовка

Требуется: Ubuntu/Debian, root, Docker, Python 3, OpenSSL, OpenSSH, systemd, `flock`, установленная eGames-нода с **Caddy**, действующий сертификат домена и доступ к панели Remnawave. На панели должен существовать пользователь для SSH/SFTP (в примере `lendry`). На ноде должен быть рабочий REALITY на TCP/443.

**Для панели один раз** подключите постоянный каталог к контейнеру `remnawave` через Compose override:

```yaml
# /opt/remnawave/docker-compose.override.yml
services:
  remnawave:
    volumes:
      - type: bind
        source: /opt/remnawave/xray-ssl
        target: /var/lib/remnawave/configs/xray/ssl
        read_only: true
```

Сначала сделайте `cp -a /opt/remnawave/docker-compose.yml /root/remnawave-compose.backup.yml` и проверьте `docker compose config`. Только после этого на панели выполните `cd /opt/remnawave && docker compose up -d --no-deps remnawave`, затем убедитесь, что панель `healthy`. **Не перезаписывайте существующий override:** если он есть, аккуратно дополните раздел `volumes` сервиса `remnawave`. Не используйте `docker compose down`.

Ниже предполагается, что `setup.sh` взят из доверенного GitHub-репозитория и его содержание проверено перед запуском. **Не используйте** `curl ... | bash`: установщик должен запускаться из обычного файла, чтобы сохранить собственную копию для systemd-таймеров.

Для одной команды на новой ноде (после eGames) используйте:

```bash
tmp=$(mktemp) && curl -fsSL https://raw.githubusercontent.com/LendryHD/remnawave-xhttp-hy2/main/setup.sh -o "$tmp" && sudo bash "$tmp" node node.example.com PANEL_IPV4 lendry; rm -f "$tmp"
```

Замените домен и IP панели. Для строгого контроля версий вместо `main` используйте заранее проверенный commit SHA. Команда меняет локальный Caddyfile ноды и открывает UDP/443 — для действующих серверов сначала изучите скрипт и резервную копию.

## Быстрый запуск одной командой

После штатной установки ноды через eGames с Caddy и подключения к Remnawave можно скачать скрипт и запустить его **одной командой на ноде**:

```bash
curl -fsSLo /tmp/remnawave-xhttp-hy2-setup.sh https://raw.githubusercontent.com/LendryHD/remnawave-xhttp-hy2/main/setup.sh && sudo bash /tmp/remnawave-xhttp-hy2-setup.sh node node.example.com 203.0.113.10 lendry
```

Замените `node.example.com` на **домен ноды**, `203.0.113.10` на **IP панели Remnawave**, `lendry` на пользователя SSH панели. **Проверьте содержимое скрипта перед запуском**; для максимально воспроизводимой установки фиксируйте проверенный commit вместо `main`.

Эта команда автоматизирует **настройку самой ноды**, но не создание входящих подключений/хостов в веб-панели и не первоначальную регистрацию её SSH-ключа на панели. Эти шаги описаны ниже. Не запускайте на боевой ноде до успешной проверки на тестовом сервере.

## Установка дополнения на ноду

**На ноде**, уже установленной через `rr → 1 → 3` или `rr → 1 → 4` с Caddy:

```bash
sudo bash setup.sh node NODE_DOMAIN PANEL_IPV4 lendry
```

Пример с условными значениями:

```bash
sudo bash setup.sh node node.example.com 203.0.113.10 lendry
```

Команда: создаст резервную копию Caddyfile; дополнит маршрут XHTTP; проверит `caddy validate`; перезапустит только `caddy-remnawave`; откроет UDP/443 в UFW; установит таймер `rw-hy2-push-node.example.com.timer`; выведет **публичный** SSH-ключ. Приватный ключ останется в `/opt/remnawave-hy2/keys/` с доступом только root.

Если XHTTP уже есть (как на действующей ноде), установка не изменит маршрут повторно. Если версия Caddyfile отличается от поддерживаемого шаблона eGames, скрипт остановится без подмены неизвестной конфигурации.

Проверка:

```bash
sudo bash setup.sh status node.example.com
sudo systemctl status rw-hy2-push-node.example.com.timer --no-pager
```

**Важно:** таймер отправки ещё не сможет войти на панель, пока публичный ключ не зарегистрирован там.

## Разрешение передачи сертификата на панели

**На панели** запустите:

```bash
sudo bash setup.sh panel NODE_DOMAIN NODE_PUBLIC_IPV4 'ssh-ed25519 AAAA... hy2-sync-node.example.com' lendry
```

Вводите ключ **целиком одной строкой** и именно публичный IP ноды, от которого пойдёт SSH. Скрипт добавляет в `authorized_keys` разрешение только с этого IP, с `restrict` и принудительным `sftp-server`. Вход по паролю, под root и интерактивную оболочку он не включает.

Если используете вход SSH **по NetBird**, в `NODE_PUBLIC_IPV4` указывайте фактический адрес-источник NetBird. Не отключайте действующие правила SSH.

Путь доставки: `/home/lendry/.hy2-transfer/NODE_DOMAIN/`. Туда поступают файлы `fullchain.pem` и `privkey.key`, на финальной панели они попадают в `/opt/remnawave/xray-ssl/NODE_DOMAIN/`. После регистрации ключа на панели **на ноде** сначала проверьте отпечаток её SSH-хоста, затем добавьте подтверждённый ключ в `/root/.ssh/known_hosts`. Условный пример проверки:

```bash
# На ПАНЕЛИ: доверенный отпечаток
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
# На НОДЕ: сравнить с отпечатком, затем получить и проверить удалённый ключ
ssh-keyscan -t ed25519 PANEL_IP > /tmp/panel-host-key
ssh-keygen -lf /tmp/panel-host-key
# Добавлять только ПОСЛЕ совпадения отпечатков:
cat /tmp/panel-host-key >> /root/.ssh/known_hosts
rm -f /tmp/panel-host-key
```

Сразу проверить доставку:

```bash
# НА НОДЕ
sudo bash setup.sh node-sync node.example.com 203.0.113.10 lendry
# НА ПАНЕЛИ
sudo bash setup.sh panel-sync
sudo ls -l /opt/remnawave/xray-ssl/node.example.com/
```

`panel-sync` принимает файл, только если домен присутствует в сертификате, до истечения остаётся не менее 7 дней, и открытый ключ сертификата соответствует закрытому ключу. Неверную пару он не применяет.

## Конфигурационный профиль Remnawave

На **панели Remnawave** откройте **Управление → Конфигурационные профили → профиль ноды → JSON**. Сохраните резервную копию исходного JSON. Скрипт выводит файл:

```text
/opt/remnawave-hy2/examples/NODE_DOMAIN/inbounds.json
```

Он содержит **два элемента массива**: VLESS XHTTP и Hysteria2. Вставьте их *в массив `inbounds` существующего профиля*, не удаляя действующий REALITY inbound и другие настройки. Не вставляйте внешний `[...]` как вложенный массив. Должны быть 3 объекта:

1. `Russia` или другой существующий Reality inbound — оставить без изменений;
2. `NODE_DOMAIN-XHTTP` — `vless`, `network: xhttp`, `security: none`, Unix-сокет `/dev/shm/xrxh.socket,0666`, `path: /xhttppath/`, `mode: auto`;
3. `NODE_DOMAIN-HY2` — `protocol: hysteria`, `version: 2`, `network: hysteria`, `security: tls`, UDP/443, `ALPN h3`, `congestion: bbr`, сертификаты из `/var/lib/remnawave/configs/xray/ssl/NODE_DOMAIN/`.

В **Ноды → Управление → нужная нода → Конфигурационный профиль** выделите все нужные inbound, нажмите **Применить/Сохранить**. Если новый inbound не появляется на ноде, выполните принудительный перезапуск **именно этой ноды** из интерфейса панели. Проверьте `ss -lunp | grep ':443'`, `ss -lntp | grep ':443'` и `ls -l /dev/shm/xrxh.socket` на сервере ноды.

Не заполняйте `clients` вручную: Remnawave делает это на основании пользователей.

## Настройка хостов в панели

Создайте по отдельному хосту на каждый новый inbound. Параметры выставляются **на веб-панели**, а не в Caddyfile панели.

| Поле панели | VLESS XHTTP | Hysteria2 |
|---|---|---|
| Название | `Node XHTTP` | `Node Hysteria2` |
| Inbound | `NODE_DOMAIN-XHTTP` | `NODE_DOMAIN-HY2` |
| Адрес | `node.example.com` | `node.example.com` |
| Внешний порт | `443` | `443` |
| Security | `tls` | `tls` |
| SNI | `node.example.com` | `node.example.com` |
| ALPN | `h2` | `h3` |
| Path | `/xhttppath/` | Пусто |
| Mode | `auto` | — |
| Flow | Пусто | — |
| Fingerprint | `chrome` по желанию | по умолчанию |
| Allow insecure | Выкл. | Выкл. |

Привяжите хост к нужной ноде и внутренней группе пользователей. Обновите подписку в HAPP и проверьте доступность интернета **по каждому протоколу отдельно**. Для XHTTP `curl -i https://node.example.com/xhttppath/` может вернуть `HTTP 400` с `x-padding` — это признак прохождения HTTP-маршрута, но окончательная проверка только через клиента.

## Автоматическое обновление сертификата

1. **Caddy ноды** автоматически продлевает свой ACME-сертификат.
2. Таймер ноды каждые 12 часов получает актуальный `.crt` и `.key` из `caddy-remnawave`, проверяет пару и отправляет по SFTP на панель.
3. Таймер панели каждые 30 минут валидирует пару и копирует её в каталог, доступный Remnawave только для чтения.
4. **Применение:** если не настроен API-токен, создаётся `/opt/remnawave-hy2/state/NODE_DOMAIN.needs-apply` и администратор выполняет **Force Restart одной ноды в панели**. Это честный полуавтоматический режим; без применения Xray может продолжать использовать старую копию.
5. **Полный автоматический режим — опционально:** создайте на панели Remnawave API-токен для управления нодами и файл `/etc/remnawave-hy2/restart-NODE_DOMAIN.env` (доступ только root):

```bash
sudo install -d -m 700 /etc/remnawave-hy2
sudo nano /etc/remnawave-hy2/restart-node.example.com.env
sudo chmod 600 /etc/remnawave-hy2/restart-node.example.com.env
```

Содержимое файла (НЕ публиковать в GitHub):

```bash
PANEL_API_URL='http://127.0.0.1:3000'
NODE_UUID='00000000-0000-0000-0000-000000000000'
API_TOKEN='TOKEN_FROM_PANEL_SETTINGS'
```

`NODE_UUID` берётся в разделе **Ноды → нужная нода**. Права токена должны позволять перезапускать ноды. После обновления сертификата скрипт отправляет `POST /api/nodes/{uuid}/actions/restart` с `{"forceRestart":true}` через loopback панели. **Этот API-вызов требует проверки на вашей версии Remnawave; до проверки не включайте его на боевой панели.** Файл `.needs-apply` удаляется только при HTTP 200/202/204. Если API недоступен, статус сохраняется и запрос будет повторён в следующий цикл.

Применение через API может кратковременно прерывать пользовательские подключения. Вручную запускать проверку сертификатов можно командами:

```bash
# Нода
sudo /opt/remnawave-hy2/setup.sh node-sync node.example.com PANEL_IP lendry
# Панель
sudo /opt/remnawave-hy2/setup.sh panel-sync
```

Срок сертификата проверяйте как в панели, так и по внешнему TLS. Следите за журналом:

```bash
journalctl -u rw-hy2-push-node.example.com.service --no-pager -n 30
journalctl -u rw-hy2-panel-sync.service --no-pager -n 30
```

## Проверки, ошибки и откат

- `XHTTP socket missing`: проверьте отметку inbound на ноде; если JSON уже сохранён, используйте штатный **Force Restart** и `docker exec remnanode cli --dump-config` (не публикуйте полный конфиг — содержит секреты).
- `Caddy 502`: проверьте, что `/dev/shm/xrxh.socket` появился и каталог `/dev/shm` общий.
- `Hysteria2 не работает`: `ss -lunp | grep ':443'`, `ufw status`, проверить сертификат и настройки хоста `ALPN h3/SNI`.
- `Permission denied (publickey)`: сверить публичный ключ, адрес-источник, разрешение `authorized_keys`, права `.ssh`, отпечаток SSH-хоста.
- `Cannot check cert`: Caddy может хранить сертификат у другого ACME-провайдера; скрипт ищет `.crt` по домену во всём `/data/caddy/certificates`.
- `needs-apply`: выполните **Force Restart только целевой ноды** в панели и после успеха удалите marker `rm /opt/remnawave-hy2/state/NODE_DOMAIN.needs-apply`, если API не используется.

Откат маршрута: резервные копии `/opt/remnanode/Caddyfile.bak.*`; выберите нужную проверенную копию, замените Caddyfile, проведите `docker exec caddy-remnawave caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile`, затем `docker restart caddy-remnawave`. Не удаляйте REALITY inbound. Для отключения HY2 снимите соответствующую галочку в панели, затем удалите только правило `443/udp`, если оно больше никому не нужно.

## Добавление следующей ноды

1. Через eGames установите ноду с Caddy и NetBird; убедитесь, что REALITY маскировка открывается по HTTPS.
2. Скачайте и проверьте `setup.sh`, на **новой ноде** запустите `sudo bash setup.sh node NODE_DOMAIN PANEL_IP lendry`.
3. На **панели** одной командой зарегистрируйте показанный публичный ключ: `sudo bash setup.sh panel NODE_DOMAIN NODE_PUBLIC_IP 'ssh-ed25519 ...' lendry`.
4. На ноде проверьте fingerprint панели и `sudo bash setup.sh node-sync NODE_DOMAIN PANEL_IP lendry`.
5. На панели выполните `sudo bash setup.sh panel-sync` и проверьте наличие сертификата в контейнере `remnawave`.
6. В панели вставьте два inbound в профиль, выберите их для ноды и создайте два Host согласно таблице.
7. Проверьте HAPP и автоматические таймеры.

**Честно о «одной команде»:** серверная настройка ноды занимает одну команду *после eGames*. Но первое доверенное подключение к панели и заполнение профиля/хостов требуют действий администратора. Чтобы убрать их, придётся отдельно разработать интеграцию с API Remnawave с правами записи конфигураций и безопасной регистрацией ключей.

## Безопасность

- Никогда не публикуйте `privkey.key`, SSH-приватные ключи, токены API панели, `SECRET_KEY`, ссылки на подписки и полный вывод `docker exec remnanode cli --dump-config`.
- Приватный сертификат находится в панели **потому, что Remnawave сама передаёт TLS-файлы ноде**; это штатная, но чувствительная к компрометации схема.
- SSH-ключ автоматической передачи допускается только с IP данной ноды и принудительно запускает SFTP без PTY/форвардинга. Для удаления ноды нужно удалить ровно её строку из `/home/lendry/.ssh/authorized_keys`, убрать её systemd-таймеры и закрытые файлы по домену.
- Временный ключ `hy2-transfer-temp`, использованный при первой ручной передаче сертификата, **после успешного подключения нового ключа** удалить с панели из `authorized_keys` и с ноды `/root/.ssh/hy2-transfer-key*`.
- Ни один рабочий сайт панели, MFA или адрес подписок не требуется закрывать или менять.

## Источники

- [Remnawave: TLS-файлы для ноды](https://docs.rw/install/remnawave-node/)
- [eGames: установка отдельной ноды с Caddy](https://wiki.egam.es/ru/installation/node-only/)
- [Remnawave: профиль и выбор inbound](https://docs.rw/learn-en/nodes/)
- [Xray: TLS и автоматическая перезагрузка сертификата](https://github.com/XTLS/Xray-docs-next/blob/main/docs/ru/config/transports/tls.md)
- [Caddy: reverse_proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)

## Лицензия

MIT. Проект не является официальным компонентом Remnawave или eGames.