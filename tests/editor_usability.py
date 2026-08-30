#!/usr/bin/env python3
from __future__ import annotations
import fcntl, os, pty, select, signal, struct, tempfile, termios, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def drain(fd,t=.18):
    out=b''; end=time.monotonic()+t
    while time.monotonic()<end:
        r,_,_=select.select([fd],[],[],.02)
        if not r: continue
        try: out+=os.read(fd,65536)
        except OSError: break
    return out

def spawn(path):
    pid,fd=pty.fork()
    if pid==0: os.execv(str(ROOT/'lace'),[str(ROOT/'lace'),str(path)])
    fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack('HHHH',24,100,0,0))
    time.sleep(.12);drain(fd,.3);return pid,fd

def finish(pid,fd):
    end=time.monotonic()+4
    while time.monotonic()<end:
        got,st=os.waitpid(pid,os.WNOHANG)
        if got: os.close(fd); return os.waitstatus_to_exitcode(st)
        drain(fd,.03)
    os.kill(pid,signal.SIGKILL);os.waitpid(pid,0);raise RuntimeError('editor did not exit')

def test_visual_and_indent():
    with tempfile.TemporaryDirectory() as td:
        p=Path(td)/'x.l';p.write_text('abcd\n')
        pid,fd=spawn(p)
        os.write(fd,b'v');time.sleep(.04);frame=drain(fd,.15)
        assert b'VISUAL' in frame and b'48;5;238m' in frame,frame[-1500:]
        os.write(fd,b'lld:wq\r');assert finish(pid,fd)==0
        assert p.read_text()=='d\n',repr(p.read_text())

    with tempfile.TemporaryDirectory() as td:
        p=Path(td)/'x.l';p.write_text('if (true) {\n}\n')
        pid,fd=spawn(p)
        os.write(fd,b'A\rvalue\x1b:wq\r');assert finish(pid,fd)==0
        assert p.read_text()=='if (true) {\n    value\n}\n',repr(p.read_text())

def test_insert_controls_and_line_indent():
    with tempfile.TemporaryDirectory() as td:
        p=Path(td)/'x.l';p.write_text('alpha beta\n')
        pid,fd=spawn(p)
        os.write(fd,b'A gamma\x17delta\x1b:wq\r');assert finish(pid,fd)==0
        assert p.read_text()=='alpha beta delta\n',repr(p.read_text())
    with tempfile.TemporaryDirectory() as td:
        p=Path(td)/'x.l';p.write_text('a\nb\n')
        pid,fd=spawn(p)
        os.write(fd,b'>>j<<:wq\r');assert finish(pid,fd)==0
        assert p.read_text()=='    a\nb\n',repr(p.read_text())

def main():
    test_visual_and_indent();test_insert_controls_and_line_indent();print('lace usability PTY PASS')
if __name__=='__main__':main()
