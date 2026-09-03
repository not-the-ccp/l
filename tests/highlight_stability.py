#!/usr/bin/env python3
from __future__ import annotations
import fcntl,os,pty,select,signal,struct,tempfile,termios,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
LEGACY=ROOT/'build'/'lace-legacy'
SYNC=b'\x1b[?2026h'
CYAN=b'\x1b[38;5;75m'

def drain(fd,t=.3):
 out=b'';end=time.monotonic()+t
 while time.monotonic()<end:
  r,_,_=select.select([fd],[],[],.02)
  if r:
   try:out+=os.read(fd,65536)
   except OSError:break
 return out
assert LEGACY.is_file(),'build/lace-legacy was not built'
with tempfile.TemporaryDirectory() as td:
 p=Path(td)/'x.l';p.write_text('foo\nbar\n')
 pid,fd=pty.fork()
 if pid==0:os.execv(str(LEGACY),[str(LEGACY),str(p),'python3',str(ROOT/'tests/fake_lsp_delayed.py')])
 fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack('HHHH',24,90,0,0));time.sleep(.35);drain(fd,.5)
 os.write(fd,b'oX\x1b');time.sleep(.12);out=drain(fd,.25)
 frames=out.split(SYNC);last=frames[-1] if frames else out
 assert (b'\x1b[38;5;81mfoo' in last or b'\x1b[38;5;75mfoo' in last),last[-2000:]
 os.write(fd,b':q!\r');time.sleep(.1)
 try:os.waitpid(pid,0)
 except:pass
 os.close(fd)
print('legacy highlight cache stability PASS')
