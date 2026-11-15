#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
bash -n setup.sh
python3 -m json.tool /dev/null >/dev/null 2>&1 || true
bash setup.sh > /tmp/hy2-usage.$$ 2>&1 || true
grep -q 'migrate DOMAIN PANEL_IP' /tmp/hy2-usage.$$
grep -q 'api-setup DOMAIN NODE_UUID' /tmp/hy2-usage.$$
rm -f /tmp/hy2-usage.$$

testdir=$(mktemp -d)
trap 'rm -rf "$testdir"' EXIT
export TEST_TMP="$testdir"
# Функции sourced только для безопасных юнит-тестов. Запуск не меняет файлов в /etc и /opt.
source ./setup.sh
valid_domain ru.synet.pw
! valid_domain 'evil;echo X'
valid_uuid '12345678-1234-1234-1234-123456789abc'
! valid_uuid 'abc'

# Проверка сертификатов пары (локальные тестовые ключи)
openssl req -new -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout "$testdir/cert.key" -out "$testdir/cert.crt" -days 30 -subj '/CN=ru.synet.pw' >/dev/null 2>&1
check_pair "$testdir/cert.crt" "$testdir/cert.key" 'ru.synet.pw'
! check_pair "$testdir/cert.crt" "$testdir/cert.key" 'wrong.example.org'

# Токен должен читаться из файла root-only и НЕ попадать в argv curl.
API_TOKEN_FILE="$testdir/token"
printf '%s' 'test-api-token-1234567890' > "$API_TOKEN_FILE"
chmod 600 "$API_TOKEN_FILE"
cat > "$testdir/curl" <<'CURL'
#!/bin/bash
set -euo pipefail
for i in "$@"; do
  [[ "$i" != *'test-api-token-1234567890'* ]] || exit 77
  if [[ "$i" == @* ]]; then
    [[ $(cat "${i#@}") == 'Authorization: Bearer test-api-token-1234567890' ]] || exit 78
  fi
done
printf 200
CURL
chmod 700 "$testdir/curl"
PATH="$testdir:$PATH"
[[ $(api_http GET http://127.0.0.1:3000/api/nodes/12345678-1234-1234-1234-123456789abc) == 200 ]]
[[ $(api_http POST http://127.0.0.1:3000/api/nodes/12345678-1234-1234-1234-123456789abc/actions/restart) == 200 ]]

python3 - <<'PY'
from pathlib import Path
s = Path('setup.sh').read_text()
checks = [
    'reverse_proxy unix+h2c//dev/shm/xrxh.socket',
    '"forceRestart":true',
    'Authorization: Bearer %s',
    'read -rs -p',
    'rw-hy2-push-',
    'rw-hy2-panel-sync',
    'StrictHostKeyChecking=yes',
    'command="%s -d %s/%s"',
    'cleanup_legacy_panel',
    'cleanup_legacy_node',
]
for item in checks:
    assert item in s, item
assert '-H "Authorization: Bearer $' not in s
assert 'API_TOKEN=' not in s
print('PASS: syntax, certificate pair, API header, redaction and static checks')
PY