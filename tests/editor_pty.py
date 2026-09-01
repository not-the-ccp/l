#!/usr/bin/env python3
from __future__ import annotations
import fcntl, os, pty, select, signal, struct, tempfile, termios, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def drain(fd,idle=.02,timeout=3):
    out=b''; end=time.monotonic()+timeout
    while time.monotonic()<end:
        r,_,_=select.select([fd],[],[],idle)
        if not r:
            if out: break
            continue
        try: b=os.read(fd,65536)
        except OSError: break
        if not b: break
        out+=b
    return out

def run():
    with tempfile.TemporaryDirectory() as td:
        path=Path(td)/'x.json'; path.write_text('{"a":1}\n',encoding='utf-8')
        pid,fd=pty.fork()
        if pid==0: os.execv(str(ROOT/'le'),[str(ROOT/'le'),str(path)])
        fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack('HHHH',30,100,0,0)); drain(fd,timeout=5)
        # $, h, i; insert through normal modal input. Then allow the idle
        # incremental didChange to reach the actual JSON LSP.
        os.write(fd,b'$hi,"b":2'); drain(fd)
        os.write(fd,b'\x1b'); time.sleep(.1); drain(fd,timeout=.4)
        # Formatting is an explicit LSP request and therefore acts as a useful
        # synchronization barrier: if editor/server documents disagree this
        # normally produces the wrong result.
        os.write(fd,b'='); drain(fd,timeout=4)
        os.write(fd,b':wq\r')
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            got,_=os.waitpid(pid,os.WNOHANG)
            if got==pid: break
            drain(fd,idle=.005,timeout=.03); time.sleep(.005)
        else:
            os.kill(pid,signal.SIGKILL); os.waitpid(pid,0); raise RuntimeError('editor failed to quit')
        os.close(fd)
        text=path.read_text(encoding='utf-8')
        assert '"a": 1' in text and '"b": 2' in text,repr(text)
    print('native editor + exact incremental JSON LSP PASS')
if __name__=='__main__':run()
