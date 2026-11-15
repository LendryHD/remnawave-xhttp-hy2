#!/usr/bin/env python3
"""Test hidden interactive token entry against a local fake Remnawave API."""
import os
import stat
import tempfile
from pathlib import Path
from threading import Thread
from http.server import BaseHTTPRequestHandler, HTTPServer
import pexpect

if os.geteuid():
    print('SKIP: interactive api-setup test requires root')
    raise SystemExit(0)

class FakeAPI(BaseHTTPRequestHandler):
    def do_GET(self):
        assert self.path == '/api/nodes/12345678-1234-1234-1234-123456789abc'
        assert self.headers.get('Authorization') == 'Bearer fake-secret-token-12345678'
        self.send_response(200)
        self.end_headers()
    def log_message(self, *_):
        pass

server = HTTPServer(('127.0.0.1', 0), FakeAPI)
thread = Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    with tempfile.TemporaryDirectory() as d:
        shell_script = Path(__file__).resolve().parents[1] / 'setup.sh'
        cmd = (
            f'source "{shell_script}"; '
            f'CRED_DIR="{d}"; '
            f'PANEL_API_URL=http://127.0.0.1:{server.server_port}; '
            'DOMAIN=ru.synet.pw; '
            'NODE_UUID=12345678-1234-1234-1234-123456789abc; '
            'api_configure'
        )
        child=pexpect.spawn('bash',['-c',cmd], encoding='utf-8', timeout=10)
        child.expect('ввод скрыт')
        child.sendline('fake-secret-token-12345678')
        child.expect(pexpect.EOF)
        output = child.before
        assert child.exitstatus == 0, (child.exitstatus, output)
        assert 'fake-secret-token' not in output, output
        token = Path(d) / 'node-ru.synet.pw.token'
        meta = Path(d) / 'node-ru.synet.pw.meta'
        assert token.read_text() == 'fake-secret-token-12345678'
        assert meta.read_text().strip() == '12345678-1234-1234-1234-123456789abc'
        assert stat.S_IMODE(token.stat().st_mode) == 0o600
        assert stat.S_IMODE(meta.stat().st_mode) == 0o600
        print('PASS: interactive hidden token input, validation and root-only storage')
finally:
    server.shutdown()
    server.server_close()