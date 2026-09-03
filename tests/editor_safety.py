#!/usr/bin/env python3
from __future__ import annotations
import fcntl, os, pty, select, signal, struct, subprocess, tempfile, termios, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
LEGACY=ROOT/'build'/'lace-legacy'

def drain(fd, timeout=.25):
    out=b''; end=time.monotonic()+timeout
    while time.monotonic()<end:
        r,_,_=select.select([fd],[],[],.02)
        if not r: continue
        try: out+=os.read(fd,65536)
        except OSError: break
    return out

def wait_exit(pid,fd,timeout=4):
    out=b''; end=time.monotonic()+timeout
    while time.monotonic()<end:
        out+=drain(fd,.03)
        got,st=os.waitpid(pid,os.WNOHANG)
        if got==pid:return os.waitstatus_to_exitcode(st),out
    os.kill(pid,signal.SIGKILL);os.waitpid(pid,0);raise RuntimeError('process failed to exit')

def spawn_editor(path):
    pid,fd=pty.fork()
    if pid==0: os.execv(str(LEGACY),[str(LEGACY),str(path)])
    fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack('HHHH',26,110,0,0))
    time.sleep(.15);drain(fd,.5)
    return pid,fd

def ctrl_c_dirty_buffer():
    with tempfile.TemporaryDirectory() as td:
        p=Path(td)/'x.l'; original='pub fn main() {\n}\n';p.write_text(original)
        pid,fd=spawn_editor(p)
        os.write(fd,b'iXYZ\x03');time.sleep(.08);drain(fd)
        assert os.waitpid(pid,os.WNOHANG)[0]==0,'Ctrl-C killed editor in insert mode'
        os.write(fd,b':q\r');time.sleep(.08);out=drain(fd)
        assert os.waitpid(pid,os.WNOHANG)[0]==0,'dirty :q exited editor'
        assert b'unsaved changes' in out
        os.write(fd,b':q!\r');code,_=wait_exit(pid,fd)
        os.close(fd);assert code==0 and p.read_text()==original

def shell_escape():
    with tempfile.TemporaryDirectory() as td:
        p=Path(td)/'space name.l';p.write_text('pub fn main() {\n}\n')
        pid,fd=spawn_editor(p)
        os.write(fd,b':!echo FILE=%\r');time.sleep(.15);out=drain(fd,.8)
        assert b'FILE=' in out and os.fsencode(str(p)) in out, out[-1000:]
        os.write(fd,b'\r');time.sleep(.08);drain(fd)
        os.write(fd,b':!sleep 5\r');time.sleep(.2);drain(fd,.1);os.write(fd,b'\x03');time.sleep(.2);out=drain(fd,.8)
        assert os.waitpid(pid,os.WNOHANG)[0]==0,'Ctrl-C during :! killed editor'
        assert b'exited 130' in out or b'exited 128' in out or b'press Enter' in out
        os.write(fd,b'\r');time.sleep(.05);drain(fd)
        os.write(fd,b':q!\r');code,_=wait_exit(pid,fd);os.close(fd);assert code==0

def trap_restores_terminal():
    with tempfile.TemporaryDirectory() as td:
        src=Path(td)/'trapui.l';exe=Path(td)/'trapui'
        src.write_text('import term;\npub fn main() {\n    term.enter_ui();\n    trap;\n}\n')
        subprocess.run([str(ROOT/'lc'),str(src),'-o',str(exe)],check=True,stdout=subprocess.DEVNULL)
        master,slave=pty.openpty();initial=termios.tcgetattr(slave)
        p=subprocess.Popen([str(exe)],stdin=slave,stdout=slave,stderr=slave,close_fds=True)
        out=b''
        while p.poll() is None:
            out+=drain(master,.05)
        out+=drain(master,.1);after=termios.tcgetattr(slave)
        os.close(master);os.close(slave)
        assert p.returncode==70
        assert b'\x1b[?1049l' in out and b'\x1b[?25h' in out
        for bit in (termios.ICANON,termios.ECHO,termios.ISIG):
            assert bool(initial[3]&bit)==bool(after[3]&bit),(bit,initial[3],after[3])

def main():
    assert LEGACY.is_file(), 'build/lace-legacy was not built'
    ctrl_c_dirty_buffer();shell_escape();trap_restores_terminal();print('legacy editor terminal/shell safety PASS')
if __name__=='__main__':main()
