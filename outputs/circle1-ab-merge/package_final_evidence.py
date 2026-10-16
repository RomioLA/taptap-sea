"""Package final review evidence without changing source or historical baselines."""
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[1]
def read(name):
    return json.loads((OUT / name).read_text(encoding='utf-8-sig'))
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
def write(name, value):
    (OUT / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

run_file = 'final-checks/run-20261003T043853914928Z.json'
run = read(run_file)
protection = read('protection-result.json')
syntax = read('syntax-final.json')
lsp = read('lsp-final-result.json')
ready = read('final-source-ready.json')
unique = {row['module'].lower(): row for row in run['suiteResults']}
assert len(unique) == 40 and len(run['suiteResults']) == 45
assert run['passed'] and not run['sourceChangedDuringRun'] and syntax['passed'] and not lsp['errors']
current = {p.relative_to(ROOT).as_posix().lower(): sha(p) for p in (ROOT / 'scripts').rglob('*.lua')}
frozen = {k.lower(): v.lower() for k, v in ready['sourceHashSnapshot'].items()}
assert current == frozen and len(current) == 86
changed = [row for row in protection['a_protection']['entries'] if row['status'] != 'match']
assert {row['file'].lower() for row in changed} == {
    'scripts/tests/abintegrationtests.lua', 'scripts/tests/architectureintegrationtests.lua'}
decisions = []
for row in changed:
    name = Path(row['file']).name
    a_backup = ROOT / 'outputs/circle1-b4/pre-sync/current-c/scripts/Tests' / name
    b_backup = OUT / 'sources-before-final-review/scripts/Tests' / name
    assert sha(a_backup) == row['expected_sha256'].lower()
    decisions.append({**row, 'reviewDisposition': 'accepted_shared_test_migration',
        'reason': ('Current timed fishing, actual port, explicit throw and cloud entry fixtures; 32 cases including formal-entry negative.'
                   if name == 'ABIntegrationTests.lua' else 'B integration/system architecture coverage retained; 12 cases pass including public-method facade and World lifecycle.'),
        'originalABackup': a_backup.relative_to(ROOT).as_posix(), 'originalABackupSha256': sha(a_backup),
        'preFinalReviewB4Backup': b_backup.relative_to(ROOT).as_posix(), 'preFinalReviewB4BackupSha256': sha(b_backup)})
write('accepted-shared-test-deltas.json', {'baselineUnchanged': True,
    'rawCheckerStatus': protection['status'], 'rawCheckerExitCode': 1,
    'unreviewedMismatchCount': 0, 'decisions': decisions,
    'scopeLimit': 'Only the two reviewed shared-test changes are accepted; no generic bypass or baseline rewrite.'})
root_changes = ['scripts/Game/Game.lua', 'scripts/Gameplay/GameClock.lua',
    'scripts/Gameplay/Circle1B2Barrel.lua', 'scripts/Tests/ABIntegrationTests.lua',
    'scripts/Tests/Circle1B2BarrelTests.lua', 'scripts/Tests/Circle1ABMergeFrameBudgetTests.lua']
summary = {
    'createdAtUtc': datetime.now(timezone.utc).isoformat(), 'status': 'offline_composition_passed_native_and_cloud_pending',
    'workspace': ROOT.as_posix(), 'finalRegressionFile': run_file, 'finalRegressionSha256': sha(OUT / run_file),
    'suiteExecutions': 45, 'uniqueSuites': 40, 'repeatedB4Suites': 5,
    'uniqueReportedCases': sum(row.get('reportedCaseCount', 0) for row in unique.values()),
    'playerReportedAssertions': sum(row.get('reportedAssertionCount', 0) for row in unique.values()),
    'counts': run['counts'], 'frozenLuaFiles': 86, 'sourceChangedDuringRun': False,
    'sourceMatchesFinalFreeze': True, 'finalSourceReadySha256': sha(OUT / 'final-source-ready.json'),
    'syntaxPassed': syntax['passed'], 'lspFiles': lsp['filesDiagnosed'], 'lspErrorCount': len(lsp['errors']),
    'lspWarningCount': len(lsp['warnings']), 'trackedWhitespaceExitCode': read('whitespace-final.json')['exitCode'],
    'aProtectionMatched': protection['a_protection']['matched_count'], 'aProtectionTotal': 43,
    'reviewedSharedTestDeltas': len(decisions), 'a3DeliveryMatched': protection['a3_delivery']['matched_count'],
    'supplementalMatched': protection['supplemental_protection']['matched_count'],
    'historicalEvidenceUnchanged': protection['historical_evidence']['unchanged_files'],
    'rootFinalReviewSourceChanges': [{'file': p, 'sha256': sha(ROOT / p)} for p in root_changes],
    'nativeGuiPreviewVerified': False, 'nativeFrameRateVerified': False, 'realCloudSdkVerified': False,
    'gitCommitPushBuildPublishPerformed': False, 'temporaryGameplayParametersAdded': [],
    'scopeLimit': 'No project-wide clean or Circle1 completion claim. Case/assertion counts are separate units, not summed.'}
write('final-summary.json', summary)
files = []
for path in sorted(OUT.rglob('*')):
    if not path.is_file() or path.name == 'evidence-manifest.json' or '__pycache__' in path.parts:
        continue
    files.append({'file': path.relative_to(ROOT).as_posix(), 'sha256': sha(path), 'bytes': path.stat().st_size})
write('evidence-manifest.json', {'createdAtUtc': summary['createdAtUtc'], 'status': summary['status'],
    'finalRegression': run_file, 'sourceFreezeSha256': summary['finalSourceReadySha256'],
    'files': files, 'nativeGuiPreviewVerified': False, 'realCloudSdkVerified': False,
    'excludes': ['evidence-manifest.json itself', '__pycache__'],
    'preparationManifestPreserved': 'preparation-evidence-manifest.json'})
print(json.dumps({k: summary[k] for k in ('status', 'suiteExecutions', 'uniqueSuites', 'uniqueReportedCases', 'playerReportedAssertions', 'frozenLuaFiles')}))
