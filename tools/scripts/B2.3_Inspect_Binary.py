#!/usr/bin/env python3
import argparse, hashlib, json
from pathlib import Path

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--binary',required=True,type=Path)
    p.add_argument('--manifest',required=True,type=Path)
    p.add_argument('--token',action='append',default=[])
    a=p.parse_args()
    data=a.binary.read_bytes()
    tokens=[{'token':t,'found':t.encode() in data} for t in a.token]
    result={'schema':1,'binary':str(a.binary.resolve()),'size_bytes':len(data),'sha256':hashlib.sha256(data).hexdigest().upper(),'tokens':tokens,'all_tokens_found':all(x['found'] for x in tokens)}
    a.manifest.parent.mkdir(parents=True,exist_ok=True)
    a.manifest.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    for x in tokens: print(f"[{'PASS' if x['found'] else 'FAIL'}] binary token: {x['token']}")
    print('Binary SHA256:',result['sha256'])
    print('Manifest:',a.manifest)
    return 0 if result['all_tokens_found'] else 1
if __name__=='__main__': raise SystemExit(main())
