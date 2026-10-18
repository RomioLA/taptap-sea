"""Summarize actual baseline diagnostics and the generated-data byte check."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'outputs' / 'sea-view-upgrade'

def error_key(error):
    return (error['uri'].split('/scripts/', 1)[1], error['code'],
            error['range']['start']['line'], error['range']['start']['character'], error['message'])

baseline = json.loads((OUT / 'lsp-baseline.json').read_text(encoding='utf-8'))
current = json.loads((OUT / 'lsp.json').read_text(encoding='utf-8'))
old = {error_key(error) for error in baseline['errors']}
new = {error_key(error) for error in current['errors']}
data = []
for source_name, module_name in [('items.lua', 'Items.lua'), ('fish.lua', 'Fish.lua')]:
    payload = (ROOT / 'data' / source_name).read_bytes()
    generated = (ROOT / 'scripts' / 'GeneratedData' / module_name).read_bytes()
    digest = hashlib.sha256(payload).hexdigest()
    header = (f'-- GENERATED from data/{source_name}; edit the source, never this file.\n'
              '-- Regenerate: python tests/sync_runtime_data.py; verify: add --check.\n'
              f'-- Source SHA-256: {digest}\n').encode()
    normalized = lambda value: value.replace(b'\r\n', b'\n')
    data.append({'source': source_name, 'sha256': digest,
                 'strictBytesMatch': generated == header + payload,
                 'contentAndHashMatchWithNormalizedNewlines': normalized(generated) == normalized(header + payload)})

preview_path = OUT / 'preview-strength-check.json'
if not preview_path.exists():
    preview_path = OUT / 'preview-status-effects.json'
preview = json.loads(preview_path.read_text(encoding='utf-8-sig')) if preview_path.exists() else {}
result = {'lsp': {'currentErrors': len(new), 'baselineErrors': len(old),
                  'newErrors': sorted(new - old), 'resolvedErrors': sorted(old - new),
                  'allFilesReported': not current['missingDiagnostics']},
          'generatedData': data,
          'preview': {key: preview.get(key) for key in ('session_id', 'reload_id', 'state', 'process_alive', 'ready', 'result', 'evidence_available', 'reason')},
          'nativeVisualAcceptance': 'UNDETERMINED: native visual evidence has not been collected'}
(OUT / 'checks-summary.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(json.dumps(result, ensure_ascii=False))
