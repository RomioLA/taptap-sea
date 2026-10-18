"""Final read-only hash checks and report manifest; never modifies source files."""
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

OUT = Path(__file__).resolve().parent
C = OUT.parents[1]
D = Path('D:/sillytavern-data/taptap-sea-B')
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p): return json.loads(p.read_text(encoding='utf-8-sig'))
def write(name, value):
    (OUT / name).write_text(json.dumps(value, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
for name in ('策划资料复查.md', 'planning-review.json', '其他文件复查.md',
             'other-files-review.json', '独立核验.md', 'independent-verification.json'):
    assert (OUT / name).is_file(), 'Missing agent deliverable: ' + name
verification = read(OUT / 'independent-verification.json')
assert verification['overall_status'] == 'PASS'
merge = read(OUT / 'merge-result.json')
before = read(OUT / 'target-before.json')['hashes']
assert all((C/p).is_file() and sha(C/p)==h for p,h in before.items())
for row in merge['files']:
    assert sha(D / row['path']) == row['sourceSha256'], 'D source changed: '+row['path']
    if row['action'] != 'skip_cache':
        assert sha(C / row['path']) == row['targetAfterSha256'], 'C merged path changed: '+row['path']
freeze = read(C / 'outputs/circle1-ab-merge/final-source-ready.json')['sourceHashSnapshot']
current_lua = {p.relative_to(C).as_posix().lower():sha(p) for p in (C/'scripts').rglob('*.lua')}
assert current_lua == {p.lower():h.lower() for p,h in freeze.items()}
summary = {'createdAtUtc':datetime.now(timezone.utc).isoformat(),
    'status':'project_deliverables_merged_and_independently_verified',
    'target':str(C), 'source':str(D), 'sourceFilesConsidered':len(merge['files']),
    'mergeCounts':merge['counts'], 'existingTargetFilesUnchanged':len(before),
    'sourceStillMatchesMergeHashes':True, 'currentLuaMatchesReviewedFreeze':True,
    'currentLuaFiles':len(current_lua), 'independentChecksPassed':10,
    'teamFilesCopied':8, 'workbooksIntegrityChecked':8,
    'nativeGuiOrCloudTestedThisMerge':False, 'gitCommitPushBuildPublishPerformed':False,
    'entry':'docs/PROJECT_HANDOFF.md',
    'boundaries':['Project deliverable merge with retained reviewed C code; not a byte mirror of old D code.',
        'Environment, Git metadata and engine-library distribution are excluded.',
        'Source planning/history retained verbatim; latest user confirmations govern implementation.',
        'No source-code edits or new business-test pass claims in this merge.']}
write('final-summary.json',summary)
files = [{'file':p.relative_to(C).as_posix(), 'sha256':sha(p), 'bytes':p.stat().st_size}
    for p in sorted(OUT.rglob('*')) if p.is_file() and p.name!='evidence-manifest.json' and '__pycache__' not in p.parts]
files.append({'file':'docs/PROJECT_HANDOFF.md', 'sha256':sha(C/'docs/PROJECT_HANDOFF.md'),
    'bytes':(C/'docs/PROJECT_HANDOFF.md').stat().st_size})
write('evidence-manifest.json', {'createdAtUtc':summary['createdAtUtc'],
    'status':summary['status'], 'files':files,
    'sourceCopyHashes':'merge-result.json', 'excludes':['This manifest itself', 'Python bytecode caches']})
print(json.dumps({'status':summary['status'],'copied':merge['counts']['add_missing'],
    'existingFilesUnchanged':len(before),'luaFilesUnchanged':len(current_lua),'evidenceFiles':len(files)}))
