#!/usr/bin/env python3
from __future__ import annotations
import fcntl, os, pty, select, signal, struct, tempfile, termios, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
EDITOR=str(ROOT/'le')

def drain(fd,idle=.015,timeout=10):
    out=b''; start=time.perf_counter()
    while time.perf_counter()-start<timeout:
        r,_,_=select.select([fd],[],[],idle)
        if not r:
            if out: break
            continue
        try:b=os.read(fd,65536)
        except OSError:break
        if not b:break
        out+=b
    return out

def one(kib):
    line=b'// editor benchmark line 0123456789 abcdefghijklmnopqrstuvwxyz\n'
    data=(line*((kib*1024)//len(line)+1))[:kib*1024]
    with tempfile.TemporaryDirectory() as td:
        path=Path(td)/'bench.l';path.write_bytes(data)
        pid,fd=pty.fork()
        if pid==0:os.execv(EDITOR,[EDITOR,str(path)])
        fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack('HHHH',30,100,0,0))
        t=time.perf_counter();drain(fd,idle=.03,timeout=20);init=time.perf_counter()-t
        t=time.perf_counter();os.write(fd,b'iX');drain(fd);insert=time.perf_counter()-t
        t=time.perf_counter();os.write(fd,b'\r');drain(fd);newline=time.perf_counter()-t
        time.sleep(.12);drain(fd,idle=.01,timeout=.3)
        t=time.perf_counter();os.write(fd,b'\x1b');time.sleep(.01);os.write(fd,b'l');drain(fd);post=time.perf_counter()-t
        os.write(fd,b':q!\r');deadline=time.perf_counter()+5
        while time.perf_counter()<deadline:
            got,_=os.waitpid(pid,os.WNOHANG)
            if got==pid:break
            drain(fd,idle=.005,timeout=.03);time.sleep(.005)
        else:
            os.kill(pid,signal.SIGKILL);os.waitpid(pid,0);raise RuntimeError('quit timeout')
        os.close(fd);return init,insert,newline,post

def main():
    print('file       startup      insert     newline  post-sync-motion')
    for kib in (10,100,500,1024):
        a,b,c,d=one(kib)
        print(f'{kib:4} KiB  {a*1000:8.1f} ms  {b*1000:7.1f} ms  {c*1000:7.1f} ms  {d*1000:8.1f} ms')
if __name__=='__main__':main()
