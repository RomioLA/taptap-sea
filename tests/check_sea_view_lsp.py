"""Collect actual EmmyLua publishDiagnostics without changing project configuration."""
import importlib.util
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import time
import sys
import tempfile
sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'outputs' / 'sea-view-upgrade' / ('lsp-baseline.json' if '--baseline' in sys.argv else 'lsp.json')
baseline_directory = None
if '--baseline' in sys.argv:
    (ROOT / '.tmp').mkdir(exist_ok=True)
    baseline_directory = tempfile.TemporaryDirectory(prefix='sea-view-lsp-', dir=ROOT / '.tmp')
    baseline_root = Path(baseline_directory.name)
    tracked = subprocess.check_output(['git', 'ls-files', 'scripts'], cwd=ROOT, text=True).splitlines()
    for relative in tracked:
        destination = baseline_root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(subprocess.check_output(['git', 'show', 'HEAD:' + relative], cwd=ROOT))
    ROOT = baseline_root
PACKAGE = Path(r'C:\Users\80739\.taptap-maker\lua-lsp-venv\Lib\site-packages\maker_lua_lsp')
spec = importlib.util.spec_from_file_location('sea_maker_lsp', PACKAGE / '__main__.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
config = module.copy.deepcopy(module.EMMYLUA_OVERRIDE_CONFIG)
config = {k: v for k, v in config.items() if not k.startswith('$')}
config['workspace'] = {'library': [str(Path(r'C:\codex\taptap-sea\.emmylua'))], 'packages': [str(Path(r'C:\codex\taptap-sea\urhox-libs'))]}
config['runtime']['requirePattern'] = ['?.lua', '?/init.lua']
severity = json.loads((ROOT / 'scripts' / '.luarc.json').read_text(encoding='utf-8'))['diagnostics']['severity']
for key, value in severity.items(): config.setdefault('diagnostics', {}).setdefault('severity', {})[key] = value.lower()
config_requests = []
proc = subprocess.Popen([str(PACKAGE / 'bin' / 'emmylua_ls.exe'), '--log-level', 'error'],
                        cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
messages = queue.Queue()
def read():
    while True:
        headers = {}
        while True:
            line = proc.stdout.readline()
            if not line: return
            if line in (b'\r\n', b'\n'): break
            k, _, v = line.decode().partition(':')
            headers[k.lower()] = v.strip()
        messages.put(json.loads(proc.stdout.read(int(headers['content-length']))))
threading.Thread(target=read, daemon=True).start()
def send(message):
    data = json.dumps({'jsonrpc': '2.0', **message}).encode()
    proc.stdin.write(f'Content-Length: {len(data)}\r\n\r\n'.encode() + data)
    proc.stdin.flush()
paths = sorted((ROOT / 'scripts').rglob('*.lua'))
diagnostics = {}
responses = {}
initialized = False
last_update = time.monotonic()
send({'id': 1, 'method': 'initialize', 'params': {
    'processId': os.getpid(), 'rootUri': (ROOT / 'scripts').as_uri(),
    'workspaceFolders': [{'uri': (ROOT / 'scripts').as_uri(), 'name': 'sea-project'}],
    'capabilities': {'workspace': {'configuration': True}, 'textDocument': {'publishDiagnostics': {}}}}})
deadline = time.monotonic() + 40
try:
    while time.monotonic() < deadline:
        try: message = messages.get(timeout=0.25)
        except queue.Empty:
            if initialized and all(p.as_uri() in diagnostics for p in paths) and time.monotonic()-last_update > 6:
                break
            continue
        method = message.get('method')
        if method == 'workspace/configuration':
            config_requests.append(message)
            send({'id': message['id'], 'result': [config for _ in message['params']['items']]})
        elif method in ('client/registerCapability', 'window/workDoneProgress/create'):
            send({'id': message['id'], 'result': None})
        elif method == 'textDocument/publishDiagnostics':
            diagnostics[message['params']['uri']] = message['params']['diagnostics']
            last_update = time.monotonic()
        elif message.get('id') == 1 and not initialized:
            initialized = True
            responses['initialize'] = message
            send({'method': 'initialized', 'params': {}})
            for path in paths:
                send({'method': 'textDocument/didOpen', 'params': {'textDocument': {
                    'uri': path.as_uri(), 'languageId': 'lua', 'version': 1,
                    'text': path.read_text(encoding='utf-8-sig')}}})
    # Force import users to reanalyze after every dependency has been opened.
    for path in paths:
        send({'method': 'textDocument/didChange', 'params': {'textDocument': {'uri': path.as_uri(), 'version': 2}, 'contentChanges': [{'text': path.read_text(encoding='utf-8-sig')}]}})
    final_deadline = time.monotonic()+10
    while time.monotonic()<final_deadline:
        try: message=messages.get(timeout=0.25)
        except queue.Empty: continue
        if message.get('method')=='textDocument/publishDiagnostics':
            diagnostics[message['params']['uri']]=message['params']['diagnostics']
    missing = [str(p.relative_to(ROOT)) for p in paths if p.as_uri() not in diagnostics]
    errors = []
    for uri, items in diagnostics.items():
        if not uri.startswith((ROOT / 'scripts').as_uri()+'/'): continue
        for diagnostic in items:
            filtered = dict(diagnostic)
            module.apply_diagnostic_filters(filtered)
            if filtered.get('severity') == 1: errors.append({'uri': uri, **filtered})
    report = {'initialized': initialized, 'missingDiagnostics': missing, 'errors': errors,
              'diagnostics': diagnostics, 'configuration': config, 'configurationRequests': config_requests}
    OUTPUT.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding='utf-8')
    print(json.dumps({'initialized': initialized, 'missing': missing, 'configurationRequests': len(config_requests),
                      'errorCount': len(errors), 'errors': errors[:20]}, ensure_ascii=False))
finally:
    if proc.poll() is None:
        try:
            send({'id': 999, 'method': 'shutdown', 'params': None})
            send({'method': 'exit', 'params': None})
            proc.wait(timeout=2)
        except (OSError, subprocess.TimeoutExpired):
            proc.terminate(); proc.wait(timeout=3)
    if baseline_directory is not None:
        baseline_directory.cleanup()

if not initialized or missing or errors: raise SystemExit(1)
