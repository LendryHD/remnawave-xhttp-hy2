#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
bash -n setup.sh
output=$(bash setup.sh 2>&1 || true)
grep -q 'node DOMAIN PANEL_IP' <<< "$output"
python3 - <<'PY'
from pathlib import Path
s=Path('setup.sh').read_text()
for key in ('reverse_proxy unix+h2c//dev/shm/xrxh.socket', 'rw-hy2-push-', 'rw-hy2-panel-sync', 'openssl x509', 'StrictHostKeyChecking=yes'):
    assert key in s, key
print('Static checks passed')
PY
