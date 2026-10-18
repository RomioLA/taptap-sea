"""Record final file hashes and existing headless verification evidence."""
import hashlib
import json
from datetime import datetime
from pathlib import Path

OUT=Path(__file__).resolve().parent
ROOT=OUT.parents[1]
full=json.loads((OUT/'island-final/final.json').read_text(encoding='utf-8'))
lsp=json.loads((OUT/'lsp-island-final.json').read_text(encoding='utf-8'))
vectors=json.loads((OUT/'island-fix-vector-equivalence.json').read_text(encoding='utf-8'))
profile=json.loads((OUT/'island-fix-paired.json').read_text(encoding='utf-8'))
cache_path=OUT/'island-cache-checks.json'
assert len(full['suites'])==53 and all(s['passed'] for s in full['suites'])
assert not lsp['errors'] and not lsp['missing']
assert len(vectors['records'])==12 and all(r['passed'] for r in vectors['records'])
config_hash=hashlib.sha256((ROOT/'scripts/Ocean/Config.lua').read_bytes()).hexdigest().upper()
assert config_hash=='0925987ACF914F3CFAED61EB7964260C5815371C0B5C3AA75F74450694CFE9C2'
paths=('scripts/Ocean/ProjectedGeometry.lua','scripts/Ocean/Projection.lua',
       'scripts/Ocean/SeaViewArt.lua','scripts/Tests/SeaHorizonOcclusionTests.lua')
manifest={'generatedAt':datetime.now().astimezone().isoformat(),'project':str(ROOT),
    'suites':len(full['suites']),'passing':len(full['suites']),
    'reportedChecks':sum(s['subtestCount'] for s in full['suites']),
    'vectorScenarios':len(vectors['records']),
    'maxVectorCoordinateDifferencePx':max(r['maxCoordinateDifferencePx'] for r in vectors['records']),
    'lspFiles':lsp['filesDiagnosed'],'lspErrors':len(lsp['errors']),
    'lspWarnings':len(lsp['warnings']),'contentConfigSha256':config_hash,
    'sourceFiles':[{'path':p,'sha256':hashlib.sha256((ROOT/p).read_bytes()).hexdigest().upper()} for p in paths],
    'pairedProfile':str((OUT/'island-fix-paired.json').relative_to(ROOT)),
    'profileScenarios':len(profile['records']),'cacheChecksPresent':cache_path.exists(),
    'nativeFpsVerified':False,'guiVerified':False,'remoteBuildPerformed':False,
    'previewState':'stopped','previewProcessAlive':False,
    'notes':'CPU benchmark pauses GC during timing and uses process_time; no native/GPU/UI/FPS measurement. Persistent cache stores world geometry only; each Island constructs fresh projection constants.'}
if cache_path.exists():
    manifest['cacheChecks']=json.loads(cache_path.read_text(encoding='utf-8'))
    assert manifest['cacheChecks']['passed'], 'island cache checks have not passed'
    assert all(s['passed'] for s in manifest['cacheChecks']['scenarios'])
for name in ('profile_island_fix.py','verify_island_fix_vectors.py','verify_island_fix_delivery.py'):
    compile((OUT/name).read_text(encoding='utf-8'),name,'exec')
(OUT/'verification-island-fix.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps({k:v for k,v in manifest.items() if k not in ('sourceFiles','cacheChecks')},ensure_ascii=False))
