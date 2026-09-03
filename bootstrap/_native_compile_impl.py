#!/usr/bin/env python3
from __future__ import annotations
import argparse, math, os, subprocess, sys, tempfile
from pathlib import Path
from typing import Any

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
from core import *
from bytecode import BCCompiler
from sdk_cli import project_sources, make_hosts, cleanup
from run_lang import REPO, TOOLS, build_sources, SERVER_FILES, stdio_host, fs_host, sys_host, ProcessHost, TermHost

OP={name:i for i,name in enumerate([
'PUSH_UNIT','PUSH_NONE','PUSH_BOOL','PUSH_INT','PUSH_FLOAT','MAKE_BYTES','MAKE_SOME','MAKE_ARRAY','MAKE_REPEAT',
'DECL','LOAD','LOCAL_PLACE','FIELD_PLACE','VALUE_FIELD_PLACE','INDEX_PLACE','DEREF_PLACE','LOAD_PLACE','STORE_PLACE',
'DUP','POP','SCOPE_ENTER','SCOPE_ENTER_BINDINGS','SCOPE_EXIT','UNWIND','NO_BINDINGS','DROP_BINDINGS',
'JUMP','JUMP_IF_FALSE','JUMP_IF_FALSE_KEEP','JUMP_IF_TRUE_KEEP','LEN','LOCAL_INC_U64','INDEX','GET_FIELD','DEREF',
'UNARY','BIN','CAST','NEW','MAKE_STRUCT','MAKE_ENUM_ZERO','MAKE_ENUM','PUSH_FUNC','CALL_NAMED','CALL_VALUE',
'HOST_MEMBER','ARRAY_PUSH','ARRAY_POP','ARRAY_SPLICE','SAVE_MATCH_VALUE','LOAD_MATCH_VALUE','CLEAR_MATCH_VALUE',
'TRY_PATTERN','PATTERN_TO_BOOL','JUMP_IF_NO_MATCH','TRAP_MATCH','TRAP','RET'])}
TY={'unit':0,'bool':1,'i8':2,'i16':3,'i32':4,'i64':5,'u8':6,'u16':7,'u32':8,'u64':9,'f32':10,'f64':11,'ref':12,'enum':13}
BOP={x:i for i,x in enumerate(['==','!=','<','<=','>','>=','&&','||','<<','>>','&','|','^','+','-','*','/','%'])}
UOP={'!':0,'~':1,'-':2}
PK={'p_wild':0,'p_bind':1,'p_unit':2,'p_none':3,'p_some':4,'p_bool':5,'p_int':6,'p_byte':7,'p_enum':8}
HOST={
(('stdio',),'read'):0, (('stdio',),'write'):1,
(('fs',),'read'):2, (('fs',),'write'):3,
(('sys',),'args'):4, (('sys',),'exe_path'):5, (('sys',),'getenv'):6,
(('proc',),'spawn'):7, (('proc',),'write'):8, (('proc',),'read'):9, (('proc',),'read_timeout'):10, (('proc',),'close'):11, (('proc',),'shell'):12,
(('term',),'enter_raw'):13, (('term',),'leave_raw'):14, (('term',),'enter_ui'):15, (('term',),'leave_ui'):16, (('term',),'read_key'):17, (('term',),'read_key_timeout'):18,
(('term',),'write'):19, (('term',),'rows'):20, (('term',),'cols'):21,
(('proc',),'write_try'):22, (('proc',),'alive'):23, (('term',),'text_width'):24,
(('linux','fd'),'stdin'):25, (('linux','fd'),'stdout'):26, (('linux','fd'),'stderr'):27,
(('linux','fd'),'dup'):28, (('linux','fd'),'pipe'):29, (('linux','fd'),'close'):30,
(('linux','fd'),'read'):31, (('linux','fd'),'write'):32,
(('linux','process'),'spawn_exact'):33, (('linux','process'),'spawn_child'):34,
(('linux','process'),'spawn_error'):35, (('linux','process'),'group'):36,
(('linux','process'),'wait_exit'):37, (('linux','process'),'exit_code'):38,
(('linux','process'),'term_signal'):39,
(('linux','process'),'send'):40, (('linux','process'),'send_group'):41,
(('linux','process'),'sigint'):42, (('linux','process'),'sigquit'):43,
(('linux','process'),'sigterm'):44, (('linux','process'),'sigkill'):45,
(('linux','process'),'sigstop'):46, (('linux','process'),'sigtstp'):47,
(('linux','process'),'sigcont'):48, (('linux','process'),'sighup'):49,
(('linux','fs'),'cwd'):50, (('linux','fs'),'chdir'):51,
(('linux','env'),'get'):52, (('linux','env'),'entries'):53,
(('linux','env'),'set'):54, (('linux','env'),'unset'):55,
}

class NativeEmitter:
    def __init__(self, program:Program, entry:str):
        self.program=program; self.bc=BCCompiler(program.checked); self.c=self.bc.c; self.entry_name=entry
        self.strings=[];self.sidmap={}; self.blobs=[]; self.aux=[]; self.patterns=[]; self.pattern_aux=[]
        self.func_names=list(self.bc.funcs); self.fid={n:i for i,n in enumerate(self.func_names)}
        self.func_slots={}
        self._prepare_slots()
    def sid(self,s:str)->int:
        if s not in self.sidmap:self.sidmap[s]=len(self.strings);self.strings.append(s)
        return self.sidmap[s]
    def ty(self,t:Ty)->int:
        if t.kind=='unit':return TY['unit']
        if t.kind=='ref':return TY['ref']
        if t.kind=='name' and len(t.a[0])==1 and not t.a[1]:
            n=t.a[0][0]
            if n in TY:return TY[n]
        if self.c.fieldless_enum(t):return TY['enum']
        raise LangError(f'native VM cannot encode scalar type {t}')
    def names_in_pattern(self,p:N,out:set[str]):
        if p.kind=='p_bind':out.add(p.a[0]);return
        if p.kind=='p_some':self.names_in_pattern(p.a[0],out);return
        if p.kind=='p_name':
            q,subs=p.a
            if len(q)==1 and not subs:out.add(q[0])
            for x in subs:self.names_in_pattern(x,out)
    def _prepare_slots(self):
        for name,f in self.bc.funcs.items():
            ordered=[]; seen=set()
            def add(n):
                if n not in seen:seen.add(n);ordered.append(n)
            for p in f.params:add(p)
            for ins in f.code:
                if ins[0] in ('DECL','LOAD','LOCAL_PLACE','LOCAL_INC_U64'):add(ins[1])
                if ins[0]=='TRY_PATTERN':
                    ns=set();self.names_in_pattern(ins[1],ns)
                    for n in sorted(ns):add(n)
            self.func_slots[name]={n:i for i,n in enumerate(ordered)}
    def pattern(self,p:N,t:Ty,slots:dict[str,int])->int:
        k=p.kind
        if k=='p_wild': rec=(PK[k],0,0,0,None,0)
        elif k=='p_bind':rec=(PK[k],slots[p.a[0]],0,0,None,0)
        elif k=='p_unit':rec=(PK[k],0,0,0,None,0)
        elif k=='p_none':rec=(PK[k],0,0,0,None,0)
        elif k=='p_bool':rec=(PK[k],1 if p.a[0] else 0,0,0,None,0)
        elif k=='p_int':rec=(PK[k],0,0,0,None,parse_int_text(p.a[0]) & ((1<<64)-1))
        elif k=='p_byte':rec=(PK[k],0,0,0,None,p.a[0])
        elif k=='p_some':
            child=self.pattern(p.a[0],t.a[0],slots);rec=(PK[k],child,0,0,None,0)
        elif k=='p_name':
            q,subs=p.a; v=self.c._variant_for_pattern(q,t)
            if v is None:
                if len(q)==1 and not subs:rec=(PK['p_bind'],slots[q[0]],0,0,None,0)
                else: raise LangError('native unresolved pattern')
            else:
                en,vn,pts=v; child=[self.pattern(sp,pt,slots) for sp,pt in zip(subs,pts)]
                auxid=None
                if child: auxid=len(self.pattern_aux);self.pattern_aux.append(child)
                rec=(PK['p_enum'],self.sid(en),self.sid(vn),len(child),auxid,0)
        else:raise LangError('native pattern '+k)
        pid=len(self.patterns);self.patterns.append(rec);return pid
    def blob(self,b:bytes)->int:self.blobs.append(bytes(b));return len(self.blobs)-1
    def auxints(self,xs)->int:self.aux.append(tuple(xs));return len(self.aux)-1
    def cstr(self,s:str)->str:
        return '"'+s.replace('\\','\\\\').replace('"','\\"').replace('\n','\\n')+'"'
    def transform(self,fname:str,ins:tuple):
        op=ins[0]; slots=self.func_slots[fname]
        d={'op':OP.get(op)}
        if op=='PUSH_UNIT':pass
        elif op=='PUSH':
            v=ins[1]
            if v is None:d['op']=OP['PUSH_NONE']
            elif isinstance(v,bool):d.update(op=OP['PUSH_BOOL'],a=int(v))
            elif isinstance(v,int):d.update(op=OP['PUSH_INT'],a=TY['u64'],u=v&((1<<64)-1))
            elif isinstance(v,float):d.update(op=OP['PUSH_FLOAT'],a=TY['f64'],f=v)
            else:raise LangError(f'native constant unsupported {v!r}')
        elif op=='PUSH_INT':d.update(u=ins[1]&((1<<64)-1),a=self.ty(ins[2]))
        elif op=='PUSH_FLOAT':d.update(f=float(ins[1]),a=self.ty(ins[2]))
        elif op=='MAKE_BYTES':d.update(blob=self.blob(ins[1]))
        elif op in ('MAKE_SOME','DUP','POP','SCOPE_ENTER','SCOPE_ENTER_BINDINGS','SCOPE_EXIT','NO_BINDINGS','DROP_BINDINGS','INDEX','DEREF','NEW','ARRAY_PUSH','ARRAY_POP','ARRAY_SPLICE','SAVE_MATCH_VALUE','LOAD_MATCH_VALUE','CLEAR_MATCH_VALUE','PATTERN_TO_BOOL','TRAP_MATCH','TRAP','RET'):pass
        elif op in ('MAKE_ARRAY','UNWIND','JUMP','JUMP_IF_FALSE','JUMP_IF_FALSE_KEEP','JUMP_IF_TRUE_KEEP','CALL_VALUE','JUMP_IF_NO_MATCH'):d['a']=ins[1]
        elif op=='MAKE_REPEAT':pass
        elif op in ('DECL','LOAD','LOCAL_PLACE','LOCAL_INC_U64'):d['a']=slots[ins[1]]
        elif op in ('FIELD_PLACE','VALUE_FIELD_PLACE','GET_FIELD'):d['a']=self.sid(ins[1])
        elif op in ('INDEX_PLACE','DEREF_PLACE','LOAD_PLACE','STORE_PLACE','LEN'):pass
        elif op=='UNARY':d.update(a=UOP[ins[1]],b=self.ty(ins[2]))
        elif op=='BIN':d.update(a=BOP[ins[1]],b=self.ty(ins[2]))
        elif op=='CAST':d.update(a=self.ty(ins[1]),b=self.ty(ins[2]))
        elif op=='MAKE_STRUCT':d.update(a=self.sid(ins[1]),b=len(ins[2]),aux=self.auxints(self.sid(x) for x in ins[2]))
        elif op=='MAKE_ENUM_ZERO':d.update(a=self.sid(ins[1]),b=self.sid(ins[2]))
        elif op=='MAKE_ENUM':d.update(a=self.sid(ins[1]),b=self.sid(ins[2]),c=ins[3])
        elif op=='PUSH_FUNC':d['a']=self.fid[ins[1]]
        elif op=='CALL_NAMED':d.update(a=self.fid[ins[1]],b=ins[2])
        elif op=='HOST_MEMBER':
            mod=tuple(ins[1]); rest=tuple(ins[2]);
            if len(rest)!=1 or (mod,rest[0]) not in HOST:raise LangError(f'native unsupported host member {mod}.{rest}')
            d['a']=HOST[(mod,rest[0])]
        elif op=='TRY_PATTERN':d['a']=self.pattern(ins[1],ins[2],slots)
        else:raise LangError('native missing opcode '+op)
        return d
    def emit(self)->str:
        funins={n:[self.transform(n,i) for i in self.bc.funcs[n].code] for n in self.func_names}
        for n in self.func_names:self.sid(n)
        out=[];A=out.append
        A('/* generated by L bootstrap compiler */')
        A('#include "native_vm.c"')
        A('')
        A('static const char *const gen_strings[] = {')
        for s in self.strings:A('  '+self.cstr(s)+',')
        A('};')
        for i,b in enumerate(self.blobs):
            data=','.join(str(x) for x in b) or '0'
            A(f'static const unsigned char blob_data_{i}[] = {{{data}}};')
            A(f'static const LBlob blob_{i} = {{{len(b)}, blob_data_{i}}};')
        for i,xs in enumerate(self.aux):A(f'static const int aux_{i}[] = {{{",".join(map(str,xs))}}};')
        for i,xs in enumerate(self.pattern_aux):A(f'static const int paux_{i}[] = {{{",".join(map(str,xs))}}};')
        A('static const LPattern gen_patterns[] = {')
        for k,a,b,n,auxid,imm in self.patterns:
            ptr='NULL' if auxid is None else f'paux_{auxid}'
            A(f'  {{{k},{a},{b},{n},{ptr},UINT64_C({imm})}},')
        if not self.patterns:A('  {0,0,0,0,NULL,0},')
        A('};')
        for fi,n in enumerate(self.func_names):
            slots=self.func_slots[n];f=self.bc.funcs[n]
            ps=[slots[p] for p in f.params]
            A(f'static const int fn_params_{fi}[] = {{{",".join(map(str,ps))}}};' if ps else '')
            A(f'static const LIns fn_code_{fi}[] = {{')
            for d in funins[n]:
                fields=[f'.op={d["op"]}']
                for x in ('a','b','c'):
                    if x in d:fields.append(f'.{x}={d[x]}')
                if 'u' in d:fields.append(f'.u=UINT64_C({d["u"]})')
                if 'f' in d:
                    f=d['f']
                    if math.isnan(f):fs='NAN'
                    elif math.isinf(f):fs='INFINITY' if f>0 else '-INFINITY'
                    else:fs=repr(float(f))
                    fields.append(f'.f={fs}')
                if 'blob' in d:fields.append(f'.ptr=&blob_{d["blob"]}')
                if 'aux' in d:fields.append(f'.ptr=aux_{d["aux"]}')
                A('  {'+','.join(fields)+'},')
            A('};')
        A('static const LFunc gen_funcs[] = {')
        for fi,n in enumerate(self.func_names):
            f=self.bc.funcs[n]; slots=self.func_slots[n]
            A(f'  {{{self.sid(n)},{len(f.params)},{(f"fn_params_{fi}" if f.params else "NULL")},{len(slots)},{len(f.code)},fn_code_{fi}}},')
        A('};')
        entryid=self.fid[self.entry_name]
        A(f'static const LProgram gen_program = {{{len(self.func_names)},gen_funcs,{entryid},{len(self.strings)},gen_strings,{len(self.patterns)},gen_patterns}};')
        A('int main(int argc,char **argv){return lvm_run(&gen_program,argc,argv);}')
        return '\n'.join(out)+'\n'


def default_hosts(args=()):
    return make_hosts(list(args))

def build_user(entry:Path,root:Path|None=None):
    root=root or entry.resolve().parent
    sources,mod=project_sources(entry,root)
    hosts,ph,th=default_hosts([])
    try:
        try:
            p=Program(sources,hosts)
        except LangError as e:
            m=getattr(e,'module',None)
            if m:
                candidate=root.joinpath(*m).with_suffix('.l')
                if candidate.is_file(): e.path=candidate
                elif tuple(m)==tuple(mod): e.path=entry
            raise
        en=internal_name(mod,'main')
        if en not in p.checked.checker.funcs:raise LangError('entry module has no main')
        return p,en
    finally: cleanup(ph,th)

def build_tool(kind:str):
    if kind=='editor':
        ph=ProcessHost();th=TermHost();hosts={('proc',):ph.module(),('term',):th.module(),('fs',):fs_host(),('sys',):sys_host([])}
        p=Program(build_sources(TOOLS/'lace/lace.l',editor=True),hosts);return p,internal_name(('main',),'main')
    name={'lsp-l':'slang-lsp','lsp-json':'json-lsp','lsp-ini':'ini-lsp'}[kind]
    p=Program(build_sources(SERVER_FILES[name]),{('stdio',):stdio_host()});return p,internal_name(('main',),'main')

def compile_native(program:Program,entry:str,out:Path,emit_c:Path|None=None,cc:str='cc'):
    src=NativeEmitter(program,entry).emit()
    if emit_c:
        emit_c.write_text(src);cpath=emit_c;tmp=None
    else:
        td=tempfile.TemporaryDirectory(prefix='lc-');tmp=td;cpath=Path(td.name)/'program.c';cpath.write_text(src)
    cmd=[cc,'-std=gnu11','-O3','-DNDEBUG','-w','-I',str(REPO/'runtime'),str(cpath),'-lm','-o',str(out)]
    subprocess.run(cmd,check=True)
    if tmp:tmp.cleanup()


def main():
    ap=argparse.ArgumentParser(description='bootstrap L -> native C VM compiler')
    ap.add_argument('source',nargs='?')
    ap.add_argument('-o','--output',required=True)
    ap.add_argument('--root')
    ap.add_argument('--emit-c')
    ap.add_argument('--tool',choices=['editor','lsp-l','lsp-json','lsp-ini'])
    ap.add_argument('--cc',default=os.environ.get('CC','cc'))
    ns=ap.parse_args();out=Path(ns.output).resolve()
    if ns.tool:p,e=build_tool(ns.tool)
    else:
        if not ns.source:ap.error('source required unless --tool')
        p,e=build_user(Path(ns.source),Path(ns.root).resolve() if ns.root else None)
    compile_native(p,e,out,Path(ns.emit_c).resolve() if ns.emit_c else None,ns.cc)
    return 0
if __name__=='__main__':raise SystemExit(main())
