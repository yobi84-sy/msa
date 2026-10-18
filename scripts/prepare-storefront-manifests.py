"""Update only reviewed release metadata after images have been built; keep current tags intact."""
from pathlib import Path
import re
def prepare(text,service):
    if service not in {'product','ordering'}:return text
    if not re.search(r'^  namespace: soldesk\s*$',text,re.M):raise ValueError('Unexpected namespace')
    if 'name: JWT_SECRET_KEY' not in text:
        match=re.search(r'(?m)^(\s*)- name: DB_HOST\s*$',text)
        if not match:raise ValueError('Expected one DB_HOST env entry')
        indent=match.group(1)
        entry='\n'.join([indent+'- name: JWT_SECRET_KEY',indent+'  valueFrom:',indent+'    secretKeyRef:',indent+'      name: jwt-secrets',indent+'      key: JWT_SECRET_KEY'])+'\n'
        text=text[:match.start()]+entry+text[match.start():]
    if service=='ordering' and 'argocd.argoproj.io/sync-wave' not in text:
        text=text.replace('  namespace: soldesk\n','  namespace: soldesk\n  annotations:\n    argocd.argoproj.io/sync-wave: "-10"\n',1)
    if service=='ordering' and 'serviceAccountName: order-notifications' not in text:
        if '      containers:' not in text:raise ValueError('Missing ordering Pod specification')
        text=text.replace('      containers:','      serviceAccountName: order-notifications\n      containers:',1)
        if '        env:' not in text:raise ValueError('Missing ordering environment')
        text=text.replace('        env:','        envFrom:\n        - configMapRef:\n            name: order-notifications\n        env:',1)
    return text
if __name__=='__main__':
    for service in ('product','ordering'):
        p=Path('msa')/service/'k8s/depl_svc.yml';p.write_text(prepare(p.read_text(encoding='utf-8-sig'),service),encoding='utf-8')
