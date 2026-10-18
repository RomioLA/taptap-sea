"""Read-only C/D delivery inventory; no copy, deletion or source modification."""
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

C = Path('C:/codex/taptap-sea')
D = Path('D:/sillytavern-data/taptap-sea-B')
OUT = C / 'outputs/circle1-ab-merge'
def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()
def load(p):
    return json.loads(p.read_text(encoding='utf-8-sig'))
def inventory(root, folder):
    path = root / folder
    return {p.relative_to(root).as_posix().lower(): p for p in path.rglob('*') if p.is_file()}

report = {'createdAtUtc': datetime.now(timezone.utc).isoformat(), 'source': str(D), 'target': str(C),
    'scope': 'scripts/docs/data/assets; no outputs history, engine library, project environment or credentials compared.',
    'fullProjectMergeCompleted': False, 'writesProductionOrPlanning': False, 'groups': {}}
for folder in ('scripts', 'docs', 'data', 'assets'):
    c, d = inventory(C, folder), inventory(D, folder)
    records = []
    for key in sorted(set(c) | set(d)):
        cp, dp = c.get(key), d.get(key)
        ch, dh = sha(cp) if cp else None, sha(dp) if dp else None
        status = 'onlyC' if not dp else 'missingFromC' if not cp else 'same' if ch == dh else 'different'
        records.append({'relativePath': (dp or cp).relative_to(D if dp else C).as_posix(),
            'status': status, 'cSha256': ch, 'dSha256': dh})
    counts = {status: sum(r['status'] == status for r in records)
              for status in ('onlyC', 'missingFromC', 'same', 'different')}
    report['groups'][folder] = {'cFiles': len(c), 'dFiles': len(d), 'counts': counts, 'records': records,
        'interpretation': 'Difference is inventory evidence, not automatic copy authorization or a runtime bug.'}

syncs = []
for file in ('source-sync-production.json', 'source-sync-tests.json'):
    for row in load(C / 'outputs/circle1-b4' / file):
        target = C / row['path']
        actual = sha(target) if target.is_file() else None
        syncs.append({'manifest': file, 'path': row['path'], 'existsInC': target.is_file(),
            'matchesPreB4SyncHash': actual == row['targetSha256'].lower(), 'currentSha256': actual,
            'preB4SyncSha256': row['targetSha256'],
            'interpretation': 'A changed hash may be the reviewed B4/root correction; absence is a separate issue.'})
report['selectedSyncRecords'] = syncs
ready = load(OUT / 'final-source-ready.json')['sourceHashSnapshot']
current = {p.relative_to(C).as_posix().lower(): sha(p) for p in (C / 'scripts').rglob('*.lua')}
expected = {k.lower(): v.lower() for k,v in ready.items()}
report['currentLuaMatchesFinalReviewedFreeze'] = current == expected
report['frozenLuaFiles'] = len(expected)
(OUT / 'merge-scope-audit.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
print(json.dumps({'groups': {k:{'cFiles':v['cFiles'], 'dFiles':v['dFiles'], 'counts':v['counts'],
    'missing': [r['relativePath'] for r in v['records'] if r['status']=='missingFromC']} for k,v in report['groups'].items()},
    'selectedSyncCount':len(syncs), 'selectedSyncMissing': [r['path'] for r in syncs if not r['existsInC']],
    'currentLuaMatchesFinalReviewedFreeze':report['currentLuaMatchesFinalReviewedFreeze']}, ensure_ascii=False))
