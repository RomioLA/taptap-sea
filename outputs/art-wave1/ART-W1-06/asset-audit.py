from pathlib import Path
from PIL import Image, ImageOps
from datetime import datetime
import hashlib, json, math, os, statistics
ROOT=Path(__file__).resolve().parents[3]
OUT=Path(__file__).resolve().parent
ROOTS=[('assets/image',ROOT/'assets/image'),('assets/generated',ROOT/'assets/generated')]
EXTS={'.png','.jpg','.jpeg'}
def signature():
    items=[]
    for _,base in ROOTS:
        if base.exists():
            for p in base.rglob('*'):
                if p.is_file():
                    s=p.stat(); items.append((p.relative_to(ROOT).as_posix(),s.st_size,s.st_mtime_ns))
    return sorted(items)
def group(rel):
    s=rel.lower()
    if Path(rel).name.lower().startswith('lp_'): return 'LP'
    if 'reading_sea_watercolor' in s or 'readingseawatercolor' in s: return 'ReadingSeaWatercolor'
    if 'oceanstory' in s: return 'OceanStory'
    if 'oceanloop' in s: return 'OceanLoop'
    if 'oceanready' in s: return 'OceanReady'
    return '其他'
def sha256(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
    return h.hexdigest()
def phash(rel):
    with Image.open(ROOT/rel) as im:
        rgba=im.convert('RGBA'); bg=Image.new('RGBA',rgba.size,(255,255,255,255)); bg.alpha_composite(rgba)
        px=list(ImageOps.grayscale(bg.convert('RGB')).resize((32,32),Image.Resampling.LANCZOS).get_flattened_data())
    n=32; coeff=[]
    for u in range(8):
        cu=[math.cos((2*x+1)*u*math.pi/(2*n)) for x in range(n)]
        for v in range(8):
            if u==0 and v==0: continue
            cv=[math.cos((2*y+1)*v*math.pi/(2*n)) for y in range(n)]
            coeff.append(sum(cu[x]*sum(px[x*n+y]*cv[y] for y in range(n)) for x in range(n)))
    med=statistics.median(coeff); value=0
    for c in coeff: value=(value<<1)|(c>med)
    return f'{value:016x}'
def bits(a,b): return (int(a,16)^int(b,16)).bit_count()
before=signature(); rows=[]; errors=[]
for prefix,base in ROOTS:
    if not base.exists(): continue
    for p in sorted(x for x in base.rglob('*') if x.is_file() and x.suffix.lower() in EXTS):
        rel=p.relative_to(ROOT).as_posix()
        rec={'relativePath':rel,'group':group(rel),'fileType':'image/png' if p.suffix.lower()=='.png' else 'image/jpeg','extension':p.suffix.lower(),'fileSizeBytes':p.stat().st_size,'sha256':sha256(p)}
        try:
            with Image.open(p) as im:
                w,h=im.size; rgba=im.convert('RGBA'); hist=rgba.getchannel('A').histogram(); bb=rgba.getchannel('A').getbbox(); n=w*h
                rec.update(width=w,height=h,sourceMode=im.mode,hasAlpha=('A' in im.mode or 'transparency' in im.info),subjectBounds=list(bb) if bb else None,transparentPixelRatio=round(hist[0]/n,8),partialAlphaPixelRatio=round(sum(hist[1:255])/n,8),perceptualHashPHash63=phash(rel))
        except Exception as e: rec['decodeError']=str(e); errors.append({'relativePath':rel,'error':str(e)})
        rows.append(rec)
relations=[]; imgroot=ROOT/'assets/image'
for mf in sorted(imgroot.rglob('manifest.json')):
    try: data=json.loads(mf.read_text(encoding='utf-8'))
    except Exception: continue
    for key,item in (data.get('assets') or {}).items():
        if not isinstance(item,dict): continue
        src,dst=item.get('source'),item.get('path')
        if not src or not dst or not str(src).lower().startswith('assets/image/'): continue
        runtime=('assets/'+str(dst).lstrip('/')).replace('\\','/')
        relations.append({'manifest':mf.relative_to(ROOT).as_posix(),'assetKey':key,'source':str(src).replace('\\','/'),'runtimePath':runtime,'sourceExists':(ROOT/str(src).replace('/',os.sep)).is_file(),'runtimeExists':(ROOT/runtime.replace('/',os.sep)).is_file(),'manifestStatus':item.get('status')})
byhash={}
for r in rows: byhash.setdefault(r['sha256'],[]).append(r)
exact=[]
for digest,items in byhash.items():
    if len(items)>1:
        size=items[0]['fileSizeBytes']; exact.append({'sha256':digest,'files':[x['relativePath'] for x in items],'copies':len(items),'oneCopyBytes':size,'theoreticalRedundantBytes':size*(len(items)-1)})
by={r['relativePath']:r for r in rows}; candidates={}
def add(a,b,kind,d=None):
    key=tuple(sorted((a,b))); row=candidates.setdefault(key,{'pathA':key[0],'pathB':key[1],'evidence':[]}); ev={'type':kind}
    if d is not None: ev.update(hammingDistance=d,hashBits=63)
    row['evidence'].append(ev)
for m in relations:
    a,b=m['source'],m['runtimePath']
    if a in by and b in by and a!=b and m['runtimeExists']:
        add(a,b,'manifest_source_runtime',bits(by[a]['perceptualHashPHash63'],by[b]['perceptualHashPHash63']))
valid=[r for r in rows if r.get('perceptualHashPHash63')]
for i,a in enumerate(valid):
    wa,ha=a['width'],a['height']
    for b in valid[i+1:]:
        if a['sha256']==b['sha256']: continue
        wb,hb=b['width'],b['height']; ar1,ar2=wa/ha,wb/hb
        if abs(ar1-ar2)/max(ar1,ar2)>.08 or min(wa/wb,wb/wa,ha/hb,hb/ha)<.45: continue
        d=bits(a['perceptualHashPHash63'],b['perceptualHashPHash63'])
        if d<=6: add(a['relativePath'],b['relativePath'],'perceptual_pHash',d)
pairs=sorted(candidates.values(),key=lambda q:(min((e.get('hammingDistance',64) for e in q['evidence']),default=64),q['pathA'],q['pathB']))
bygroup={}
for r in rows:
    g=bygroup.setdefault(r['group'],{'count':0,'bytes':0});g['count']+=1;g['bytes']+=r['fileSizeBytes']
dirs={}
for prefix,base in ROOTS:
    fs=[p for p in base.rglob('*') if p.is_file()] if base.exists() else []
    dirs[prefix]={'allFiles':len(fs),'allFilesBytes':sum(p.stat().st_size for p in fs),'rasterFiles':sum(1 for r in rows if r['relativePath'].startswith(prefix+'/')),'rasterBytes':sum(r['fileSizeBytes'] for r in rows if r['relativePath'].startswith(prefix+'/'))}
exact_paths={p for q in exact for p in q['files']}; dup_paths={p for q in pairs for p in (q['pathA'],q['pathB'])}; resolution=[]
for r in rows:
    tags=[]; reasons=[]; w,h=r.get('width',0),r.get('height',0); md=max(w,h); bb=r.get('subjectBounds'); area=((bb[2]-bb[0])*(bb[3]-bb[1])/(w*h)) if bb and w and h else None; name=Path(r['relativePath']).name.lower()
    links=[m for m in relations if m['source']==r['relativePath'] and m['runtimeExists']]
    if links: tags.append('LIKELY_SOURCE_ONLY'); reasons.append('项目 manifest 将该图列为另一运行图的 source，且对应文件存在；用途未定。')
    if r['relativePath'] in exact_paths: tags.append('EXACT_DUPLICATE'); reasons.append('SHA256 与另一资源完全相同；只是分析候选，不删除。')
    if r['relativePath'] in dup_paths: tags.append('POSSIBLE_DUPLICATE'); reasons.append('存在 pHash 或 source/runtime manifest 关联，需人工判断。')
    if (md>=1536) or (md>=1024 and any(t in name for t in ('图标','icon','icons','按钮','button','ui_panel'))):
        tags.append('CAN_DOWNSCALE'); reasons.append('高分辨率/图标图集启发式候选；实际显示像素尚未由玩法引用证明。')
    if r.get('transparentPixelRatio',0)>=.65 and area is not None and area<.40:
        tags.append('CAN_CROP_TRANSPARENT'); reasons.append('透明像素比例≥65%且主体 bounds 面积<画布40%；裁切需保留留边及锚点/UV。')
    if not tags: tags=['KEEP_AS_IS']; reasons=['当前筛选未标为候选；不代表最终采用判断。']
    resolution.append({'relativePath':r['relativePath'],'group':r['group'],'width':w,'height':h,'fileSizeBytes':r['fileSizeBytes'],'subjectAreaRatio':round(area,6) if area is not None else None,'tags':list(dict.fromkeys(tags)),'reasons':reasons,'sourceRuntimeRelations':[{'manifest':m['manifest'],'runtimePath':m['runtimePath']} for m in links]})
after=signature(); stable=(before==after)
inv={'schemaVersion':1,'scanTime':datetime.now().astimezone().isoformat(timespec='seconds'),'scanRoot':['assets/image/','assets/generated/'],'fileSetStableDuringScan':stable,'imageDirectory':dirs.get('assets/image',{}),'generatedDirectory':dirs.get('assets/generated',{}),'assetCount':len(rows),'decodeErrors':errors,'sourceRuntimeRelations':relations,'assets':rows}
if not stable:
    bm={p:(n,t) for p,n,t in before};am={p:(n,t) for p,n,t in after}
    inv['scanChanges']={'added':[p for p in am if p not in bm],'removed':[p for p in bm if p not in am],'modified':[p for p in bm.keys()&am.keys() if bm[p]!=am[p]]}
(OUT/'asset-inventory.json').write_text(json.dumps(inv,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
(OUT/'exact-duplicates.json').write_text(json.dumps({'method':'SHA256 exact byte equality','duplicateGroupCount':len(exact),'duplicateFileCount':sum(q['copies'] for q in exact),'redundantCopyCount':sum(q['copies']-1 for q in exact),'theoreticalRedundantBytes':sum(q['theoreticalRedundantBytes'] for q in exact),'groups':exact},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
(OUT/'possible-duplicates.json').write_text(json.dumps({'method':'pHash: alpha-composited on white, grayscale, 32x32 Lanczos thumbnail, 8x8 low-frequency DCT without DC, median threshold; compatible aspect/scale and Hamming <=6/63. Manifest source/runtime links are independent version evidence.','threshold':6,'hashBits':63,'candidatePairCount':len(pairs),'candidateAssetCount':len(set(p for q in pairs for p in (q['pathA'],q['pathB']))),'pairs':pairs},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
counts={}
for q in resolution:
    for t in q['tags']: counts[t]=counts.get(t,0)+1
(OUT/'resolution-candidates.json').write_text(json.dumps({'advisoryOnly':True,'candidateAssetCount':sum(1 for q in resolution if 'KEEP_AS_IS' not in q['tags']),'tagCounts':counts,'assets':resolution},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
top=sorted(rows,key=lambda q:q['fileSizeBytes'],reverse=True)[:20]
print(json.dumps({'scanTime':inv['scanTime'],'stableDuringScan':stable,'scanChanges':inv.get('scanChanges'),'imageDirectory':inv['imageDirectory'],'generatedDirectory':inv['generatedDirectory'],'assetCount':len(rows),'groups':bygroup,'exactGroupCount':len(exact),'exactSavings':sum(q['theoreticalRedundantBytes']for q in exact),'possiblePairCount':len(pairs),'possibleAssetCount':len(set(p for q in pairs for p in(q['pathA'],q['pathB']))),'tagCounts':counts,'top20':[{'path':q['relativePath'],'bytes':q['fileSizeBytes'],'width':q['width'],'height':q['height'],'group':q['group']}for q in top]},ensure_ascii=True))