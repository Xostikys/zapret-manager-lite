"""Run with Python 3: python tests/verify_package.py. No router/network writes."""
from pathlib import Path
import base64,hashlib,io,json,re,shutil,subprocess,tarfile
R=Path(__file__).resolve().parent.parent
script=(R/'install.sh').read_text(encoding='utf-8')
head,encoded=script.split('\n__ZM_LITE_PAYLOAD__\n',1)
payload=base64.b64decode(encoded)
digest=re.search(r"printf '%s  %s\\n' '([0-9a-f]{64})'",head).group(1)
assert hashlib.sha256(payload).hexdigest()==digest
with tarfile.open(fileobj=io.BytesIO(payload),mode='r:gz') as t:
 names=set()
 for m in t:
  assert m.isfile() and re.fullmatch(r'payload/(src|vendor)/[A-Za-z0-9_.-]+',m.name),m.name
  assert m.name not in names;names.add(m.name)
  assert t.extractfile(m).read()==(R/m.name.removeprefix('payload/')).read_bytes(),m.name
for line in (R/'src/PACKAGE.sha256').read_text().splitlines():
 digest,name=line.split('  ',1)
 assert hashlib.sha256((R/'src'/name).read_bytes()).hexdigest()==digest,name
lock=json.loads((R/'SOURCES.json').read_text())
vendor=R/'vendor/ZapretManager_LuCI.sh'
assert hashlib.sha256(vendor.read_bytes()).hexdigest()==lock['vendor_installer_sha256']
for f in list((R/'src').glob('*'))+[R/'bootstrap.sh.in',vendor]:
 assert b'\r\n' not in f.read_bytes(),f
assert 'Copyright 2026 Xostikys' in (R/'NOTICE').read_text()
assert 'Copyright 2026 StressOzz' in (R/'NOTICE').read_text()
s=vendor.read_text(encoding='utf-8')
assert 'webui()' not in s and 'callWebui' not in s
assert "cat > '/www/zm/" not in s and 'uci set uhttpd.zmweb=' not in s
shell=shutil.which('sh')
if shell:
 for f in [R/'install.sh',vendor,*list((R/'src').glob('*.sh'))]:
  subprocess.run([shell,'-n',str(f)],check=True)
else: print('SKIP shell syntax: sh is not installed')
print('PASS payload integrity, source parity, file types/paths, checksums, LF, attribution and removed standalone entrypoints')
