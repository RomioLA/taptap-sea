from pathlib import Path
import json
import hashlib
import importlib.util
import sys
sys.dont_write_bytecode=True
folder=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('review',folder/'run_review.py')
# Do not import the runner: it intentionally executes its suites at import time.
A=folder.parents[1]
B=Path('D:/sillytavern-data/taptap-sea-B')
result=json.loads((folder/'composition-results.json').read_text(encoding='utf-8'))
summary={}
for version in ('b_original','a3_b3_composed','a3_ocean_tests_composed'):
    entries=result[version]
    groups={}
    for suite in entries:
        group=suite.get('group','a3')
        record=groups.setdefault(group,{'suites':0,'passedRows':0,'failedRows':0,'skippedRows':0,'scriptPassed':0,'scriptFailed':0})
        record['suites']+=1
        rows=suite.get('tests',[])
        for row in rows:
            record['skippedRows' if row.get('skipped') else 'passedRows' if row.get('passed') else 'failedRows']+=1
        if not rows: record['scriptPassed' if suite['passed'] else 'scriptFailed']+=1
    summary[version]=groups
summary['smoke']={'passed':sum(r['passed'] for r in result['smoke']['results']),'total':len(result['smoke']['results'])}
summary['nativeVerified']=False
summary['cloudVerified']=False
summary['originalSourcesModified']=False
summary['scopeContractMismatch']=result['scope_contract_reproduction']
sources={}
diff=[]
for path in sorted((A/'scripts').rglob('*.lua')):
    relative=path.relative_to(A).as_posix()
    other=B/relative
    if not other.exists(): continue
    ah=hashlib.sha256(path.read_bytes()).hexdigest()
    bh=hashlib.sha256(other.read_bytes()).hexdigest()
    sources[relative]={'aSha256':ah,'bSha256':bh}
    if ah!=bh: diff.append(relative)
summary['differentSharedScripts']=diff
(folder/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
(folder/'source-hashes.json').write_text(json.dumps(sources,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(summary,ensure_ascii=False,indent=2))
