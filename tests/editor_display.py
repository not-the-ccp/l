#!/usr/bin/env python3
from __future__ import annotations
import fcntl,os,pty,select,signal,struct,tempfile,termios,time,re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
LEGACY=ROOT/'build'/'lace-legacy'
def drain(fd,t=.3):
 out=b'';end=time.monotonic()+t
 while time.monotonic()<end:
  r,_,_=select.select([fd],[],[],.02)
  if r:
   try:out+=os.read(fd,65536)
   except OSError:break
 return out
def cursor(out):
 xs=re.findall(rb'\x1b\[(\d+);(\d+)H',out)
 return tuple(map(int,xs[-1])) if xs else None
def check(text,keys,want):
 with tempfile.TemporaryDirectory() as td:
  p=Path(td)/'x.l';p.write_text(text)
  pid,fd=pty.fork()
  if pid==0:os.execv(str(LEGACY),[str(LEGACY),str(p)])
  fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack('HHHH',24,100,0,0));time.sleep(.12);drain(fd,.3)
  os.write(fd,keys);time.sleep(.04);out=drain(fd,.18)
  got=cursor(out);assert got==want,(text,got,want,out[-800:])
  os.write(fd,b':q!\r');time.sleep(.05)
  try:os.waitpid(pid,0)
  except:pass
  os.close(fd)
assert LEGACY.is_file(),'build/lace-legacy was not built'
check('a\tb\n',b'll',(1,13))
check('界a\n',b'l',(1,11))
check('e\u0301x\n',b'l',(1,10))
check('👩\u200d💻x\n',b'l',(1,11))
check('🇦🇹x\n',b'l',(1,11))
print('legacy Lace terminal cell positioning PASS')
