"""Merge authored delivery files into current C tree; preserve existing code/history."""
import argparse
import hashlib
import json
import shutil
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

C = Path('C:/codex/taptap-sea').resolve()
D = Path('D:/sillytavern-data/taptap-sea-B').resolve()
OUT = C / 'outputs/circle1-project-merge'
FOLDERS = ('docs', 'scripts', 'data', 'assets', 'tests', 'screenshots', 'outputs')
ROOT_FILES = ('.gitignore', 'AGENTS.md', 'CLAUDE.md')
def now(): return datetime.now(timezone.utc).isoformat()
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def write(name, value):
    (OUT / name).write_text(json.dumps(value, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
def safe(root, rel):
    p = (root / rel).resolve()
    p.relative_to(root)
    return p
def ignored(p):
    return '__pycache__' in p.parts or p.suffix.lower() in ('.pyc', '.pyo')
def files(root):
    found = {}
    for folder in FOLDERS:
        for p in (root / folder).rglob('*'):
            if p.is_file() and not p.resolve().is_relative_to(OUT):
                p.resolve().relative_to(root)
                found[p.relative_to(root).as_posix()] = p
    for name in ROOT_FILES:
        if (root / name).is_file(): found[name] = root / name
    return found
def build_plan():
    records = []
    for rel, source in sorted(files(D).items()):
        target = safe(C, rel)
        sh = sha(source)
        th = sha(target) if target.is_file() else None
        if ignored(source): action = 'skip_cache'
        elif th is None: action = 'add_missing'
        elif th == sh: action = 'keep_identical'
        elif rel.startswith(('outputs/', 'screenshots/')): action = 'archive_d_evidence_keep_c'
        elif rel.startswith(('scripts/', 'tests/')): action = 'keep_reviewed_c_code'
        else: action = 'unresolved_conflict'
        record = {'path': rel, 'sourceSha256': sh, 'sourceBytes': source.stat().st_size,
            'targetBeforeSha256': th, 'action': action}
        if action == 'archive_d_evidence_keep_c':
            record['archivePath'] = 'outputs/circle1-project-merge/d-evidence-conflicts/' + rel
        records.append(record)
    return records

parser = argparse.ArgumentParser()
parser.add_argument('--apply', action='store_true')
args = parser.parse_args()
OUT.mkdir(parents=True, exist_ok=True)
plan = build_plan()
counts = dict(Counter(row['action'] for row in plan))
write('merge-plan.json', {'createdAtUtc': now(), 'source': str(D), 'target': str(C),
    'folders': list(FOLDERS), 'rootFiles': list(ROOT_FILES), 'counts': counts, 'files': plan,
    'excluded': ['Engine/library/template/example/tool distribution directories',
        'Git, project/service/client configuration and local runtime/cache directories', 'Python bytecode caches']})
if not args.apply:
    print(json.dumps({'mode':'plan', 'counts':counts, 'unresolved':[r['path'] for r in plan if r['action']=='unresolved_conflict']}))
    raise SystemExit(0)
if any(row['action']=='unresolved_conflict' for row in plan):
    raise SystemExit('Unresolved authored-file conflict; no mutations applied.')
if (OUT / 'merge-result.json').exists():
    raise SystemExit('Existing merge result: refuse repeated apply; use separate read-only verification.')

# Freeze all existing authored files, excluding this new report directory.
before = {rel: sha(p) for rel,p in files(C).items()}
write('target-before.json', {'createdAtUtc': now(), 'hashes': before})
done = []
for row in plan:
    source = safe(D, row['path'])
    target = safe(C, row['path'])
    if sha(source) != row['sourceSha256']:
        raise RuntimeError('Source changed during merge: ' + row['path'])
    actual_before = sha(target) if target.is_file() else None
    if actual_before != row['targetBeforeSha256']:
        raise RuntimeError('Target changed during merge: ' + row['path'])
    destination = target if row['action']=='add_missing' else (
        safe(C, row['archivePath']) if row['action']=='archive_d_evidence_keep_c' else None)
    if destination is not None:
        if destination.exists(): raise RuntimeError('Refuse overwrite: ' + str(destination))
        destination.parent.mkdir(parents=True, exist_ok=True)
        with source.open('rb') as src, destination.open('xb') as dst:
            shutil.copyfileobj(src, dst)
        if sha(destination) != row['sourceSha256']:
            raise RuntimeError('Copied hash mismatch: ' + row['path'])
    done.append({**row, 'targetAfterSha256':sha(target) if target.is_file() else None,
        'archiveSha256':sha(destination) if row['action']=='archive_d_evidence_keep_c' else None})
    write('merge-progress.json', {'createdAtUtc':now(), 'completed':len(done), 'files':done})

changed_existing = [rel for rel,h in before.items() if not safe(C,rel).is_file() or sha(safe(C,rel))!=h]
assert not changed_existing, changed_existing
source_changes = [row['path'] for row in plan if sha(safe(D,row['path']))!=row['sourceSha256']]
assert not source_changes, source_changes
write('merge-result.json', {'createdAtUtc':now(), 'status':'files_merged_hash_verified',
    'source':str(D), 'target':str(C), 'counts':counts, 'existingFilesPreserved':len(before),
    'changedExistingFiles':changed_existing, 'sourceChangedDuringMerge':source_changes, 'files':done,
    'meaning':'Authored deliverables merged with explicit current-code and historical-evidence conflict decisions; not a directory mirror or Git merge.',
    'nativeGuiVerified':False, 'realCloudVerified':False})
print(json.dumps({'mode':'applied', 'counts':counts, 'existingFilesPreserved':len(before), 'changedExistingFiles':changed_existing}))
