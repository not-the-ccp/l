from __future__ import annotations
from dataclasses import dataclass
from typing import Any
from core import *

@dataclass
class BCFunc:
    name:str; params:tuple[str,...]; code:list[tuple]; ret:Ty

class BCCompiler:
    """AST -> compact stack bytecode. Generics are erased because bodies were checked parametrically."""
    def __init__(self,cm:CheckedModule):
        self.cm=cm;self.c=cm.checker;self.funcs={};self.anon={};self.seq=0
        for f in self.c.funcs.values():self.compile_fn(f)
    def emit(self,*ins):self.code.append(tuple(ins));return len(self.code)-1
    def mark(self):return len(self.code)
    def patch(self,at,target):
        x=list(self.code[at]);x[-1]=target;self.code[at]=tuple(x)
    def compile_fn(self,f:FnInfo):
        if f.name in self.funcs:return
        old=(getattr(self,'code',None),getattr(self,'loops',None),getattr(self,'scope_depth',None))
        self.code=[];self.loops=[];self.scope_depth=1
        for s in f.body:self.stmt(s)
        self.emit('PUSH_UNIT');self.emit('RET')
        self.funcs[f.name]=BCFunc(f.name,tuple(n for n,_ in f.params),self.code,f.ret)
        self.code,self.loops,self.scope_depth=old
    def anon_fn(self,e):
        key=id(e)
        if key in self.anon:return self.anon[key]
        name=f'$anon{len(self.anon)}';ps,rt,b=e.a
        old=(getattr(self,'code',None),getattr(self,'loops',None),getattr(self,'scope_depth',None));self.code=[];self.loops=[];self.scope_depth=1
        for s in b:self.stmt(s)
        self.emit('PUSH_UNIT');self.emit('RET')
        self.funcs[name]=BCFunc(name,tuple(n for n,_ in ps),self.code,rt);self.code,self.loops,self.scope_depth=old;self.anon[key]=name;return name
    def enter_scope(self,bindings=False):
        self.emit('SCOPE_ENTER_BINDINGS' if bindings else 'SCOPE_ENTER'); self.scope_depth+=1
    def exit_scope(self):
        self.emit('SCOPE_EXIT'); self.scope_depth-=1
    def emit_unwind(self,target_depth):
        n=self.scope_depth-target_depth
        if n<0: raise RuntimeError('bad compile-time scope depth')
        if n:self.emit('UNWIND',n)
    def stmt(self,s):
        k=s.kind
        if k=='var':self.expr(s.a[2]);self.emit('DECL',s.a[0]);return
        if k=='assign':
            l,op,r=s.a;self.place(l)
            if op=='=':self.expr(r)
            else:
                self.emit('DUP');self.emit('LOAD_PLACE');self.expr(r);self.emit('BIN',op[:-1],l.ty)
            self.emit('STORE_PLACE');return
        if k=='exprstmt':self.expr(s.a[0]);self.emit('POP');return
        if k=='return':
            if s.a[0] is None:self.emit('PUSH_UNIT')
            else:self.expr(s.a[0])
            self.emit('RET');return
        if k=='trap':self.emit('TRAP');return
        if k=='break':
            breaks,conts,bd,cd=self.loops[-1]; self.emit_unwind(bd); j=self.emit('JUMP',None);breaks.append(j);return
        if k=='continue':
            breaks,conts,bd,cd=self.loops[-1]; self.emit_unwind(cd); j=self.emit('JUMP',None);conts.append(j);return
        if k=='if':
            self.condition(s.a[0]); jf=self.emit('JUMP_IF_FALSE',None)
            self.enter_scope(bindings=True)
            for x in s.a[1]:self.stmt(x)
            self.exit_scope();je=self.emit('JUMP',None);self.patch(jf,self.mark())
            self.emit('DROP_BINDINGS')
            self.enter_scope()
            for x in s.a[2]:self.stmt(x)
            self.exit_scope();self.patch(je,self.mark());return
        if k=='while':
            base=self.scope_depth; start=self.mark();self.condition(s.a[0]);jf=self.emit('JUMP_IF_FALSE',None);self.enter_scope(bindings=True)
            breaks=[];conts=[];self.loops.append((breaks,conts,base,base))
            for x in s.a[1]:self.stmt(x)
            self.exit_scope();cont=self.mark();self.emit('JUMP',start)
            false_cleanup=self.mark();self.patch(jf,false_cleanup);self.emit('DROP_BINDINGS');end=self.mark()
            self.loops.pop();
            for j in breaks:self.patch(j,end)
            for j in conts:self.patch(j,cont)
            return
        if k=='for':
            init,c,step,b=s.a;pre=self.scope_depth;self.enter_scope();outer=self.scope_depth
            if init:self.stmt(init)
            start=self.mark()
            if c:self.condition(c);jf=self.emit('JUMP_IF_FALSE',None)
            else:jf=None
            breaks=[];conts=[];self.loops.append((breaks,conts,pre,outer));self.enter_scope()
            for x in b:self.stmt(x)
            self.exit_scope();cont=self.mark()
            if step:self.stmt(step)
            self.emit('JUMP',start);cleanup=self.mark()
            if jf is not None:self.patch(jf,cleanup);self.emit('DROP_BINDINGS')
            self.exit_scope();end=self.mark();self.loops.pop()
            for j in breaks:self.patch(j,end)
            for j in conts:self.patch(j,cont)
            return
        if k=='forin':
            n,e,b=s.a; self.seq+=1;av=f'$arr{self.seq}';iv=f'$i{self.seq}';pre=self.scope_depth;self.enter_scope();outer=self.scope_depth
            self.expr(e);self.emit('DECL',av);self.emit('PUSH_INT',0,name_ty('u64'));self.emit('DECL',iv)
            start=self.mark();self.emit('LOAD',iv);self.emit('LOAD',av);self.emit('LEN');self.emit('BIN','<',name_ty('u64'));jf=self.emit('JUMP_IF_FALSE',None)
            self.enter_scope();self.emit('LOAD',av);self.emit('LOAD',iv);self.emit('INDEX');self.emit('DECL',n)
            breaks=[];conts=[];self.loops.append((breaks,conts,pre,outer))
            for x in b:self.stmt(x)
            self.exit_scope();cont=self.mark();self.emit('LOCAL_INC_U64',iv);self.emit('JUMP',start);cleanup=self.mark();self.patch(jf,cleanup);self.exit_scope();end=self.mark();self.loops.pop()
            for j in breaks:self.patch(j,end)
            for j in conts:self.patch(j,cont)
            return
        if k=='match':
            self.expr(s.a[0]);self.emit('SAVE_MATCH_VALUE');end_j=[]
            for p,b in s.a[1]:
                self.emit('LOAD_MATCH_VALUE');self.emit('TRY_PATTERN',p,s.a[0].ty);jn=self.emit('JUMP_IF_NO_MATCH',None)
                self.enter_scope(bindings=True)
                for x in b:self.stmt(x)
                self.exit_scope();end_j.append(self.emit('JUMP',None));self.patch(jn,self.mark())
            self.emit('TRAP_MATCH');end=self.mark()
            for j in end_j:self.patch(j,end)
            self.emit('CLEAR_MATCH_VALUE');return
        raise LangError('bytecode compiler missing stmt '+k,s.span)
    def condition(self,c):
        if c.kind=='is':self.expr(c.a[0]);self.emit('TRY_PATTERN',c.a[1],c.a[0].ty);self.emit('PATTERN_TO_BOOL')
        else:self.expr(c);self.emit('NO_BINDINGS')
    def can_place(self,e):
        # Pure structural query.  Do not probe by emitting bytecode and catching:
        # a failed speculative probe can leave instructions behind and corrupt the
        # operand stack.  The checker has already rejected illegal assignments.
        if e.kind in ('qname','index'):return True
        if e.kind=='unary' and e.a[0]=='*':return True
        if e.kind=='field':
            b=e.a[0]
            return self.can_place(b) or (getattr(b,'ty',None) is not None and b.ty.kind=='ref')
        return False
    def place(self,e):
        if e.kind=='qname':
            q=e.a[0];self.emit('LOCAL_PLACE',q[0])
            for f in q[1:]:self.emit('FIELD_PLACE',f)
            return
        if e.kind=='index':self.expr(e.a[0]);self.expr(e.a[1]);self.emit('INDEX_PLACE');return
        if e.kind=='unary' and e.a[0]=='*':self.expr(e.a[1]);self.emit('DEREF_PLACE');return
        if e.kind=='field':
            b=e.a[0]
            if self.can_place(b):self.place(b);self.emit('FIELD_PLACE',e.a[1])
            else:self.expr(b);self.emit('VALUE_FIELD_PLACE',e.a[1])
            return
        raise LangError('bytecode place missing '+e.kind,e.span)
    def expr(self,e):
        k=e.kind
        if k=='unit':self.emit('PUSH_UNIT')
        elif k=='bool':self.emit('PUSH',e.a[0])
        elif k=='byte':self.emit('PUSH_INT',e.a[0],e.ty)
        elif k=='int':self.emit('PUSH_INT',parse_int_text(e.a[0]),e.ty)
        elif k=='float':self.emit('PUSH_FLOAT',float(e.a[0].replace('_','')),e.ty)
        elif k=='string':self.emit('MAKE_BYTES',e.a[0])
        elif k=='none':self.emit('PUSH',None)
        elif k=='some':self.expr(e.a[0]);self.emit('MAKE_SOME')
        elif k=='array':
            for x in e.a[0]:self.expr(x)
            self.emit('MAKE_ARRAY',len(e.a[0]))
        elif k=='repeat':self.expr(e.a[0]);self.expr(e.a[1]);self.emit('MAKE_REPEAT')
        elif k=='qname':
            q=e.a[0]
            if len(q)==1 and q[0] in self.c.consts:self.emit('PUSH',self.c.consts[q[0]].value)
            elif len(q)==1 and q[0] in self.c.funcs:self.emit('PUSH_FUNC',q[0])
            elif hasattr(e,'resolved_variant'):self.emit('MAKE_ENUM_ZERO',e.resolved_variant[0].a[0][0],e.resolved_variant[1])
            elif q[0] in self.c.imports:self.emit('HOST_MEMBER',self.c.imports[q[0]],q[1:])
            else:
                self.emit('LOAD',q[0])
                for f in q[1:]:self.emit('GET_FIELD',f)
        elif k=='unary':
            op,x=e.a
            if op=='*':self.expr(x);self.emit('DEREF')
            else:self.expr(x);self.emit('UNARY',op,e.ty)
        elif k=='is':
            self.expr(e.a[0]);self.emit('TRY_PATTERN',e.a[1],e.a[0].ty);self.emit('PATTERN_TO_BOOL')
        elif k=='binary':
            op,l,r=e.a
            if op=='&&':
                self.expr(l);j=self.emit('JUMP_IF_FALSE_KEEP',None);self.emit('POP');self.expr(r);self.patch(j,self.mark())
            elif op=='||':
                self.expr(l);j=self.emit('JUMP_IF_TRUE_KEEP',None);self.emit('POP');self.expr(r);self.patch(j,self.mark())
            else:self.expr(l);self.expr(r);self.emit('BIN',op,l.ty)
        elif k=='cast':self.expr(e.a[0]);self.emit('CAST',e.a[0].ty,e.ty)
        elif k=='new':self.expr(e.a[0]);self.emit('NEW')
        elif k=='index':self.expr(e.a[0]);self.expr(e.a[1]);self.emit('INDEX')
        elif k=='field':self.expr(e.a[0]);self.emit('GET_FIELD',e.a[1])
        elif k=='structlit':
            cal,fs=e.a
            for _,x in fs:self.expr(x)
            self.emit('MAKE_STRUCT',cal.a[0][0],tuple(n for n,_ in fs))
        elif k=='call':
            cal,args=e.a
            if cal.kind=='qname' and len(cal.a[0])==1 and cal.a[0][0] in ('len','push','pop','splice'):
                n=cal.a[0][0]
                for a in args:self.expr(a)
                self.emit({'len':'LEN','push':'ARRAY_PUSH','pop':'ARRAY_POP','splice':'ARRAY_SPLICE'}[n]);return
            if cal.kind=='qname' and len(cal.a[0])==1 and cal.a[0][0] in self.c.funcs:
                for a in args:self.expr(a)
                self.emit('CALL_NAMED',cal.a[0][0],len(args));return
            if hasattr(e,'resolved_variant'):
                for a in args:self.expr(a)
                self.emit('MAKE_ENUM',e.resolved_variant[0].a[0][0],e.resolved_variant[1],len(args));return
            self.expr(cal)
            for a in args:self.expr(a)
            self.emit('CALL_VALUE',len(args))
        elif k=='anonfn':self.emit('PUSH_FUNC',self.anon_fn(e))
        else:raise LangError('bytecode compiler missing expr '+k,e.span)

class BCVM:
    def __init__(self,bc:BCCompiler,host_modules=None):
        self.bc=bc;self.c=bc.c;self.host_modules=host_modules or {};self.frames=[];self.stack=[];self.match_value=None;self.pending_bind=None
        self.live_refs=weakref.WeakSet();self.live_arrays=weakref.WeakSet()
    def alloc_ref(self,v):r=RefObj(copy_value(v));self.live_refs.add(r);return r
    def alloc_array(self,xs=()):a=ArrayObj([copy_value(x) for x in xs]);self.live_arrays.add(a);return a
    def run(self,name='main',args=()):return self.call(name,list(args))
    def lookup(self,n):
        for s in reversed(self.frames[-1]['scopes']):
            if n in s:return s[n]
        raise TrapSig('unknown local '+n)
    def local_place(self,n):
        for s in reversed(self.frames[-1]['scopes']):
            if n in s:return Place(lambda s=s:s[n],lambda v,s=s:s.__setitem__(n,v))
        raise TrapSig('unknown local '+n)
    def call(self,name,args):
        f=self.bc.funcs[name];fr={'scopes':[dict(zip(f.params,[copy_value(x) for x in args]))],'ip':0,'func':f};self.frames.append(fr)
        try:return self.loop()
        finally:self.frames.pop()
    def loop(self):
        fr=self.frames[-1];code=fr['func'].code;S=self.stack
        while fr['ip']<len(code):
            ins=code[fr['ip']];fr['ip']+=1;op=ins[0]
            if op=='PUSH_UNIT':S.append(UNITV)
            elif op=='PUSH':S.append(ins[1])
            elif op=='PUSH_INT':S.append(wrap_int(ins[1],ins[2]))
            elif op=='PUSH_FLOAT':S.append(fround(ins[1],ins[2]))
            elif op=='MAKE_BYTES':S.append(self.alloc_array(ins[1]))
            elif op=='MAKE_SOME':S.append(SomeVal(copy_value(S.pop())))
            elif op=='MAKE_ARRAY':
                n=ins[1]
                if n:
                    xs=S[-n:]; del S[-n:]
                else:
                    xs=[]
                S.append(self.alloc_array(xs))
            elif op=='MAKE_REPEAT':
                n=S.pop();v=S.pop();S.append(self.alloc_array(copy_value(v) for _ in range(n)))
            elif op=='DECL':fr['scopes'][-1][ins[1]]=copy_value(S.pop())
            elif op=='LOAD':S.append(copy_value(self.lookup(ins[1])))
            elif op=='LOCAL_PLACE':S.append(self.local_place(ins[1]))
            elif op=='FIELD_PLACE':
                p=S.pop();base=p.get();f=ins[1]
                if isinstance(base,RefObj):base=base.value
                S.append(Place(lambda base=base,f=f:base.fields[f],lambda v,base=base,f=f:base.fields.__setitem__(f,v)))
            elif op=='VALUE_FIELD_PLACE':
                base=S.pop();f=ins[1]
                if isinstance(base,RefObj):base=base.value
                S.append(Place(lambda base=base,f=f:base.fields[f],lambda v,base=base,f=f:base.fields.__setitem__(f,v)))
            elif op=='INDEX_PLACE':
                i=S.pop();a=S.pop()
                if i<0 or i>=len(a.items):raise TrapSig('array index out of bounds')
                S.append(Place(lambda a=a,i=i:a.items[i],lambda v,a=a,i=i:a.items.__setitem__(i,v)))
            elif op=='DEREF_PLACE':
                r=S.pop();S.append(Place(lambda r=r:r.value,lambda v,r=r:setattr(r,'value',v)))
            elif op=='LOAD_PLACE':S.append(copy_value(S.pop().get()))
            elif op=='STORE_PLACE':
                v=S.pop();p=S.pop()
                if not isinstance(p,Place):
                    chain=[(x['func'].name,x['ip']) for x in self.frames]
                    raise RuntimeError(f'STORE_PLACE expected Place, got {type(p).__name__}={p!r}; value={type(v).__name__}; frames={chain}; stack={[type(x).__name__ for x in S[-12:]]}')
                p.set(copy_value(v))
            elif op=='DUP':S.append(S[-1])
            elif op=='POP':S.pop()
            elif op=='SCOPE_ENTER':fr['scopes'].append({})
            elif op=='SCOPE_ENTER_BINDINGS':fr['scopes'].append(self.pending_bind or {});self.pending_bind=None
            elif op=='SCOPE_EXIT':fr['scopes'].pop()
            elif op=='UNWIND':
                for _ in range(ins[1]):fr['scopes'].pop()
            elif op=='NO_BINDINGS':self.pending_bind={}
            elif op=='DROP_BINDINGS':self.pending_bind=None
            elif op=='JUMP':fr['ip']=ins[1]
            elif op=='JUMP_IF_FALSE':
                if not S.pop():fr['ip']=ins[1]
            elif op=='JUMP_IF_FALSE_KEEP':
                if not S[-1]:fr['ip']=ins[1]
            elif op=='JUMP_IF_TRUE_KEEP':
                if S[-1]:fr['ip']=ins[1]
            elif op=='LEN':S.append(len(S.pop().items))
            elif op=='LOCAL_INC_U64':p=self.local_place(ins[1]);p.set(wrap_int(p.get()+1,name_ty('u64')))
            elif op=='INDEX':
                i=S.pop();a=S.pop()
                if i<0 or i>=len(a.items):raise TrapSig('array index out of bounds')
                S.append(copy_value(a.items[i]))
            elif op=='GET_FIELD':
                v=S.pop();
                if isinstance(v,RefObj):v=v.value
                S.append(copy_value(v.fields[ins[1]]))
            elif op=='DEREF':S.append(copy_value(S.pop().value))
            elif op=='UNARY':
                u,t=ins[1],ins[2];v=S.pop();S.append((not v) if u=='!' else (wrap_int(~v,t) if u=='~' else (wrap_int(-v,t) if int_info(t) else fround(-v,t))))
            elif op=='BIN':
                b=S.pop();a=S.pop();S.append(self.scalar(ins[1],a,b,ins[2]))
            elif op=='CAST':S.append(self.c.cast_value(S.pop(),ins[1],ins[2],TrapSig))
            elif op=='NEW':S.append(self.alloc_ref(S.pop()))
            elif op=='MAKE_STRUCT':
                n,fields=ins[1],ins[2];vals=[S.pop() for _ in fields][::-1];S.append(StructVal(n,{f:copy_value(v) for f,v in zip(fields,vals)}))
            elif op=='MAKE_ENUM_ZERO':S.append(EnumVal(ins[1],ins[2],[]))
            elif op=='MAKE_ENUM':
                n,v,c=ins[1:];xs=[S.pop() for _ in range(c)][::-1];S.append(EnumVal(n,v,[copy_value(x) for x in xs]))
            elif op=='PUSH_FUNC':S.append(UserFnVal(ins[1]))
            elif op=='CALL_NAMED':
                n,c=ins[1:];args=[S.pop() for _ in range(c)][::-1];S.append(self.call(n,args))
            elif op=='CALL_VALUE':
                c=ins[1];args=[S.pop() for _ in range(c)][::-1];fv=S.pop();
                if isinstance(fv,UserFnVal):S.append(self.call(fv.name,args))
                elif isinstance(fv,HostFnVal):S.append(fv.fn(*args))
                else:raise TrapSig('not callable')
            elif op=='HOST_MEMBER':
                hm=self.host_modules[ins[1]];S.append(hm.get_value(ins[2]))
            elif op=='ARRAY_PUSH':
                v=S.pop();a=S.pop();a.items.append(copy_value(v));S.append(UNITV)
            elif op=='ARRAY_POP':
                a=S.pop()
                if not a.items:raise TrapSig('pop empty')
                S.append(copy_value(a.items.pop()))
            elif op=='ARRAY_SPLICE':
                repl=S.pop();end=S.pop();start=S.pop();a=S.pop()
                if start<0 or end<start or end>len(a.items):raise TrapSig('splice range out of bounds')
                snap=[copy_value(x) for x in repl.items]
                a.items[start:end]=snap;S.append(UNITV)
            elif op=='SAVE_MATCH_VALUE':self.match_value=S.pop()
            elif op=='LOAD_MATCH_VALUE':S.append(copy_value(self.match_value))
            elif op=='CLEAR_MATCH_VALUE':self.match_value=None
            elif op=='TRY_PATTERN':
                v=S.pop();self.pending_bind=self.match(ins[1],v,ins[2]);S.append(self.pending_bind)
            elif op=='PATTERN_TO_BOOL':S.append(S.pop() is not None)
            elif op=='JUMP_IF_NO_MATCH':
                m=S.pop()
                if m is None:fr['ip']=ins[1]
            elif op=='TRAP_MATCH':raise TrapSig('match fell through')
            elif op=='TRAP':raise TrapSig('trap')
            elif op=='RET':return copy_value(S.pop())
            else:raise RuntimeError('bad opcode '+op)
        return UNITV
    def scalar(self,op,a,b,t):
        # use a tiny Interpreter utility without frames
        fake=object.__new__(Interpreter);return Interpreter.scalar_op(fake,op,a,b,t)
    def match(self,p,v,t):
        fake=object.__new__(Interpreter);fake.c=self.c;return Interpreter.match(fake,p,v,t)
