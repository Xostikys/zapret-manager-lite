from pathlib import Path
import io, tarfile, gzip, base64, hashlib
root=Path(__file__).resolve().parent
src=root/'src'
for directory in ['src','vendor']:
 for f in (root/directory).rglob('*'):
  if f.is_symlink() or not f.is_file() or f.parent!=root/directory:
   raise ValueError('Only flat regular source files allowed: '+str(f))
  if not all(c.isascii() and (c.isalnum() or c in '._-') for c in f.name):
   raise ValueError('Unsafe source name: '+str(f))
(src/'PACKAGE.sha256').write_text(''.join(hashlib.sha256(f.read_bytes()).hexdigest()+'  '+f.relative_to(src).as_posix()+'\n' for f in sorted(src.rglob('*')) if f.is_file() and f.name!='PACKAGE.sha256'),encoding='utf-8',newline='\n')
data=io.BytesIO()
with tarfile.open(fileobj=data,mode='w',format=tarfile.USTAR_FORMAT) as tar:
 for directory in ['src','vendor']:
  for f in sorted((root/directory).rglob('*')):
   if f.is_file():
    raw=f.read_bytes();i=tarfile.TarInfo('payload/'+f.relative_to(root).as_posix())
    i.size=len(raw);i.mode=0o644;i.mtime=1794787200;tar.addfile(i,io.BytesIO(raw))
payload=gzip.compress(data.getvalue(),mtime=0)
digest=hashlib.sha256(payload).hexdigest()
template=(root/'bootstrap.sh.in').read_text(encoding='utf-8')
script=template.replace('@PAYLOAD_SHA256@',digest)
script+='\n__ZM_LITE_PAYLOAD__\n'+base64.encodebytes(payload).decode('ascii')
(root/'install.sh').write_text(script,encoding='utf-8',newline='\n')
print('Built install.sh:',len(script),'bytes; payload SHA256:',digest)
