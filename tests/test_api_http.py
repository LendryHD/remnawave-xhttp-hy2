#!/usr/bin/env python3
"""Local-only HTTP integration test; no production endpoints or secrets."""
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from threading import Thread
import subprocess
import tempfile

script = Path(__file__).resolve().parents[1] / 'setup.sh'
seen = []
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        seen.append((self.command, self.path, self.headers.get('Authorization', ''), ''))
        self.send_response(200)
        self.end_headers()
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0))).decode()
        seen.append((self.command, self.path, self.headers.get('Authorization', ''), body))
        self.send_response(202)
        self.end_headers()
    def log_message(self, *args):
        pass

server = HTTPServer(('127.0.0.1', 0), Handler)
t = Thread(target=server.serve_forever, daemon=True)
t.start()
try:
    with tempfile.TemporaryDirectory() as d:
        f = Path(d) / 'token'
        f.write_text('local-test-token-123456789')
        f.chmod(0o600)
        url = f'http://127.0.0.1:{server.server_port}/api/nodes/12345678-1234-1234-1234-123456789abc'
        code = '''source "$1"
API_TOKEN_FILE="$2"
api_http GET "$3"
echo
api_http POST "$3/actions/restart"
echo
'''
        result = subprocess.run(['bash','-c',code,'--',str(script),str(f),url], text=True,capture_output=True,timeout=5,check=True)
        assert result.stdout.splitlines()==['200','202'],result.stdout
        assert seen==[
            ('GET','/api/nodes/12345678-1234-1234-1234-123456789abc','Bearer local-test-token-123456789',''),
            ('POST','/api/nodes/12345678-1234-1234-1234-123456789abc/actions/restart','Bearer local-test-token-123456789','{"forceRestart":true}'),
        ],seen
        assert 'local-test-token' not in result.stderr
        print('PASS: local HTTP integration GET/POST, Bearer header, forceRestart payload')
finally:
    server.shutdown()
    server.server_close()