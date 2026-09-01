#!/usr/bin/env python3
from __future__ import annotations
from pathlib import Path
import os,sys,subprocess,termios,tty,shutil,time
sys.path.insert(0,str(Path(__file__).resolve().parent))
from core import *
from bytecode import BCCompiler,BCVM

HERE=Path(__file__).resolve().parent
REPO=HERE.parent
PORTABLE_LIB=REPO/'lib'/'portable'
HOSTED_LIB=REPO/'lib'/'hosted'
TOOLS=REPO/'tools'
COMMON={
 ('arrays',):PORTABLE_LIB/'arrays.l',
 ('bytes',):PORTABLE_LIB/'bytes.l',
 ('strconv',):PORTABLE_LIB/'strconv.l',
 ('utf8',):PORTABLE_LIB/'utf8.l',
 ('json',):PORTABLE_LIB/'json.l',
 ('lsp',):PORTABLE_LIB/'lsp.l',
 ('slang_syntax',):PORTABLE_LIB/'slang_syntax.l',
 ('server',):TOOLS/'lsp/server.l',
 ('slang',):TOOLS/'lsp/slang.l',
 ('json_server_impl',):TOOLS/'lsp/json_server_impl.l',
 ('ini_server_impl',):TOOLS/'lsp/ini_server_impl.l',
}
SERVER_FILES={
 'slang-lsp':TOOLS/'lsp/slang_server.l',
 'json-lsp':TOOLS/'lsp/json_server.l',
 'ini-lsp':TOOLS/'lsp/ini_server.l',
}

def array_bytes(data:bytes): return ArrayObj(data)
def to_bytes(v): return bytes(v.items)
def array_strings(xs): return ArrayObj([array_bytes(os.fsencode(x) if isinstance(x,str) else x) for x in xs])

def stdio_host():
    h=HostModule(('stdio',))
    def rd(n):
        b=os.read(0,max(1,min(int(n),1<<20)))
        return None if not b else SomeVal(array_bytes(b))
    def wr(a):
        data=to_bytes(a);off=0
        while off<len(data):off+=os.write(1,data[off:])
        return UNITV
    h.function('read',[name_ty('u64')],opt(arr(name_ty('u8'))),rd)
    h.function('write',[arr(name_ty('u8'))],UNIT,wr)
    return h

class ProcessHost:
    def __init__(self):self.ps=[]
    def module(self):
        h=HostModule(('proc',));pt=h.opaque_type('Process')
        def spawn(argv):
            args=[os.fsdecode(bytes(x.items)) for x in argv.items]
            if not args:raise TrapSig('proc.spawn requires nonempty argv')
            p=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,bufsize=0,start_new_session=True)
            self.ps.append(p);return OpaqueVal(('proc','Process'),p)
        def write(pv,data):
            p=pv.payload;b=to_bytes(data)
            if p.stdin is None:raise TrapSig('process stdin closed')
            p.stdin.write(b);p.stdin.flush();return UNITV
        def read(pv,n):
            p=pv.payload
            if p.stdout is None:return None
            b=os.read(p.stdout.fileno(),max(1,min(int(n),1<<20)))
            return None if not b else SomeVal(array_bytes(b))
        def close(pv):self.close_one(pv.payload);return UNITV
        h.function('spawn',[arr(arr(name_ty('u8')))],pt,spawn)
        h.function('write',[pt,arr(name_ty('u8'))],UNIT,write)
        h.function('read',[pt,name_ty('u64')],opt(arr(name_ty('u8'))),read)
        def read_timeout(pv,n,ms):
            import select
            p=pv.payload
            if p.stdout is None:return None
            r,_,_=select.select([p.stdout],[],[],max(0,int(ms))/1000.0)
            if not r:return None
            b=os.read(p.stdout.fileno(),max(1,min(int(n),1<<20)))
            return None if not b else SomeVal(array_bytes(b))
        h.function('read_timeout',[pt,name_ty('u64'),name_ty('u64')],opt(arr(name_ty('u8'))),read_timeout)
        def shell(command):
            cmd=os.fsdecode(to_bytes(command))
            return int(subprocess.call(cmd,shell=True,executable='/bin/sh'))
        h.function('close',[pt],UNIT,close)
        h.function('shell',[arr(name_ty('u8'))],name_ty('i64'),shell)
        def write_try(pv,data):
            p=pv.payload;b=to_bytes(data)
            if p.stdin is None:return False
            try:p.stdin.write(b);p.stdin.flush();return True
            except (BrokenPipeError,OSError):return False
        h.function('write_try',[pt,arr(name_ty('u8'))],name_ty('bool'),write_try)
        h.function('alive',[pt],name_ty('bool'),lambda pv: pv.payload.poll() is None)
        return h
    def close_one(self,p):
        if p.poll() is not None:return
        try:
            if p.stdin:p.stdin.close()
            p.wait(timeout=2)
        except Exception:
            try:p.terminate();p.wait(timeout=1)
            except Exception:
                try:p.kill()
                except Exception:pass
    def cleanup(self):
        for p in self.ps:self.close_one(p)

class TermHost:
    def __init__(self):self.saved=None
    def module(self):
        h=HostModule(('term',))
        h.function('enter_raw',[],UNIT,self.enter)
        h.function('leave_raw',[],UNIT,self.leave)
        h.function('enter_ui',[],UNIT,self.enter_ui)
        h.function('leave_ui',[],UNIT,self.leave_ui)
        h.function('read_key',[],opt(arr(name_ty('u8'))),self.read_key)
        def read_key_timeout(ms):
            import select
            r,_,_=select.select([0],[],[],max(0,int(ms))/1000.0)
            if not r:return None
            return self.read_key()
        h.function('read_key_timeout',[name_ty('u64')],opt(arr(name_ty('u8'))),read_key_timeout)
        h.function('write',[arr(name_ty('u8'))],UNIT,self.write)
        h.function('rows',[],name_ty('u64'),lambda:shutil.get_terminal_size((80,24)).lines)
        h.function('cols',[],name_ty('u64'),lambda:shutil.get_terminal_size((80,24)).columns)
        def text_width(value):
            import unicodedata
            text=to_bytes(value).decode('utf-8','replace'); total=0; i=0; join=False; regional=False
            while i<len(text):
                cp=ord(text[i]); ch=text[i]; i+=1
                if cp==0x200d:
                    join=True; continue
                if unicodedata.combining(ch) or 0xFE00<=cp<=0xFE0F or 0x1F3FB<=cp<=0x1F3FF:
                    continue
                if 0x1F1E6<=cp<=0x1F1FF:
                    if regional: regional=False; continue
                    total+=2; regional=True; continue
                regional=False
                w=2 if unicodedata.east_asian_width(ch) in ('W','F') else 1
                if join:
                    join=False; continue
                total+=w
            return total
        h.function('text_width',[arr(name_ty('u8'))],name_ty('u64'),text_width)
        return h
    def enter(self):
        if os.isatty(0) and self.saved is None:self.saved=termios.tcgetattr(0);tty.setraw(0)
        return UNITV
    def leave(self):
        if self.saved is not None:
            termios.tcsetattr(0,termios.TCSADRAIN,self.saved);self.saved=None
        return UNITV
    def enter_ui(self):
        self.enter(); self.write(array_bytes(b'\x1b[?1049h\x1b[?25h')); return UNITV
    def leave_ui(self):
        self.write(array_bytes(b'\x1b[0m\x1b[?25h\x1b[?1049l')); self.leave(); return UNITV
    def read_key(self):
        b=os.read(0,1);return None if not b else SomeVal(array_bytes(b))
    def write(self,a):
        b=to_bytes(a);off=0
        while off<len(b):off+=os.write(1,b[off:])
        return UNITV

def fs_host():
    h=HostModule(('fs',))
    def rd(path):
        try:return SomeVal(array_bytes(Path(os.fsdecode(to_bytes(path))).read_bytes()))
        except FileNotFoundError:return None
    def wr(path,data):
        try:Path(os.fsdecode(to_bytes(path))).write_bytes(to_bytes(data));return True
        except OSError:return False
    h.function('read',[arr(name_ty('u8'))],opt(arr(name_ty('u8'))),rd)
    h.function('write',[arr(name_ty('u8')),arr(name_ty('u8'))],name_ty('bool'),wr)
    return h

def sys_host(args):
    h=HostModule(('sys',));h.function('args',[],arr(arr(name_ty('u8'))),lambda:array_strings(args));h.function('exe_path',[],arr(name_ty('u8')),lambda:array_bytes(os.fsencode(sys.executable)))
    def getenv(name):
        value=os.environ.get(os.fsdecode(to_bytes(name)))
        return None if value is None else SomeVal(array_bytes(os.fsencode(value)))
    h.function('getenv',[arr(name_ty('u8'))],opt(arr(name_ty('u8'))),getenv);return h

def build_sources(main_path:Path,editor=False):
    if editor:
        keep={('arrays',),('bytes',),('strconv',),('utf8',),('json',),('lsp',)}
        d={k:p.read_text() for k,p in COMMON.items() if k in keep}
        d[('lsp_client',)]=(HOSTED_LIB/'lsp_client.l').read_text()
    else:
        d={k:p.read_text() for k,p in COMMON.items()}
    d[('main',)]=main_path.read_text();return d

def execute(program,hosts,use_vm=False):
    if not use_vm:return program.run(('main',))
    return BCVM(BCCompiler(program.checked),hosts).run(internal_name(('main',),'main'))

def run_server(name,use_vm=False):
    hosts={('stdio',):stdio_host()};p=Program(build_sources(SERVER_FILES[name]),hosts);execute(p,hosts,use_vm)

def run_editor(path,server_kind,use_vm=False):
    ph=ProcessHost();th=TermHost()
    server_argv=[sys.executable,str(HERE/'run_lang.py'),server_kind]
    hosts={('proc',):ph.module(),('term',):th.module(),('fs',):fs_host(),('sys',):sys_host([path,*server_argv])}
    try:
        p=Program(build_sources(TOOLS/'lace/lace.l',editor=True),hosts);execute(p,hosts,use_vm)
    finally:th.leave();ph.cleanup()

def main():
    if len(sys.argv)>=2:
        cmd=sys.argv[1];use_vm=cmd.endswith('-vm');base=cmd[:-3] if use_vm else cmd
        if base in SERVER_FILES:run_server(base,use_vm);return 0
    if len(sys.argv)>=3 and sys.argv[1] in ('editor','editor-vm'):
        use_vm=sys.argv[1]=='editor-vm'
        kind=sys.argv[3] if len(sys.argv)>=4 else ('json-lsp' if sys.argv[2].endswith('.json') else 'ini-lsp' if sys.argv[2].endswith('.ini') else 'slang-lsp')
        run_editor(sys.argv[2],kind,use_vm);return 0
    print('usage: run_lang.py {slang-lsp|json-lsp|ini-lsp} | editor FILE [SERVER]',file=sys.stderr);return 2
if __name__=='__main__':raise SystemExit(main())
