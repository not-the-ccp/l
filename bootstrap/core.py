from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any, Callable, Iterable
import math, struct, weakref, gc

# ---------- diagnostics / source ----------

@dataclass(frozen=True)
class Span:
    start: int; end: int; line: int; col: int; end_line: int; end_col: int

@dataclass(frozen=True)
class Tok:
    kind: str; text: str; span: Span; raw: str|None=None

class LangError(Exception):
    def __init__(self, msg: str, span: Span|None=None):
        super().__init__(msg); self.msg=msg; self.span=span

KEYWORDS = {
    'import','as','pub','const','struct','enum','fn','var','if','else','while','for','in','match',
    'return','break','continue','trap','true','false','none','some','ref','new','is',
}
MULTI = ['<<=','>>=','==','!=','<=','>=','&&','||','<<','>>','+=','-=','*=','/=','%=','&=','|=','^=','->']
SINGLE = set('(){}[],:;.?+-*/%~!<>=&|^')
ESC = {'n':10,'r':13,'t':9,'0':0,"'":39,'"':34,'\\':92}

class Lexer:
    """Byte-oriented syntax over valid Python str (our study assumes UTF-8 source before this stage)."""
    def __init__(self, src:str, keep_comments:bool=False):
        self.src=src; self.keep_comments=keep_comments
    def lex(self)->list[Tok]:
        s=self.src; out=[]; i=0; line=1; col=1; n=len(s)
        def span(st,sl,sc,en,el,ec): return Span(st,en,sl,sc,el,ec)
        def advance(txt):
            nonlocal line,col
            parts=txt.split('\n')
            if len(parts)==1: col += len(txt)
            else: line += len(parts)-1; col = len(parts[-1])+1
        while i<n:
            c=s[i]
            if c in ' \t\r\n':
                st=i; sl=line; sc=col
                while i<n and s[i] in ' \t\r\n': i+=1
                advance(s[st:i]); continue
            if s.startswith('//',i):
                st=i; sl=line; sc=col; j=s.find('\n',i)
                if j<0:j=n
                txt=s[i:j]
                if self.keep_comments: out.append(Tok('COMMENT',txt,span(st,sl,sc,j,line,col+len(txt))))
                advance(txt); i=j; continue
            st=i; sl=line; sc=col
            if c.isascii() and (c.isalpha() or c=='_'):
                i+=1
                while i<n and s[i].isascii() and (s[i].isalnum() or s[i]=='_'): i+=1
                txt=s[st:i]; advance(txt)
                out.append(Tok(txt if txt in KEYWORDS else 'NAME',txt,span(st,sl,sc,i,line,col))); continue
            # numbers: strict underscores only between digits; decimal leading zeroes allowed
            if c.isdigit():
                i+=1
                if c=='0' and i<n and s[i] in 'xXbB':
                    base=s[i]; i+=1; valid='01' if base in 'bB' else '0123456789abcdefABCDEF'
                    if i>=n or s[i] not in valid: raise LangError('expected digit after numeric base prefix', span(st,sl,sc,i,line,col+(i-st)))
                    prev_digit=False
                    while i<n:
                        ch=s[i]
                        if ch in valid: prev_digit=True; i+=1
                        elif ch=='_' and prev_digit and i+1<n and s[i+1] in valid: prev_digit=False; i+=1
                        else: break
                    txt=s[st:i]; advance(txt); out.append(Tok('INT',txt,span(st,sl,sc,i,line,col))); continue
                # decimal / float
                def digits(pos):
                    p=pos; prev=True
                    while p<n:
                        if s[p].isdigit(): prev=True; p+=1
                        elif s[p]=='_' and prev and p+1<n and s[p+1].isdigit(): prev=False; p+=1
                        else: break
                    return p
                i=digits(i); isfloat=False
                if i<n and s[i]=='.' and i+1<n and s[i+1].isdigit():
                    isfloat=True; i=digits(i+1)
                if i<n and s[i] in 'eE':
                    p=i+1
                    if p<n and s[p] in '+-':p+=1
                    if p<n and s[p].isdigit(): isfloat=True; i=digits(p)
                txt=s[st:i]; advance(txt); out.append(Tok('FLOAT' if isfloat else 'INT',txt,span(st,sl,sc,i,line,col))); continue
            if c in "'\"":
                quote=c; i+=1; raw=[]
                while i<n and s[i]!=quote:
                    if s[i]=='\n': raise LangError('literal cannot cross a line', span(st,sl,sc,i,line,col+(i-st)))
                    if s[i]=='\\':
                        if i+1>=n: raise LangError('unfinished escape', span(st,sl,sc,i,line,col+(i-st)))
                        e=s[i+1]
                        if e=='x':
                            if i+3>=n or any(ch not in '0123456789abcdefABCDEF' for ch in s[i+2:i+4]): raise LangError('bad \\x escape')
                            raw.append(int(s[i+2:i+4],16)); i+=4
                        elif e in ESC: raw.append(ESC[e]); i+=2
                        else: raise LangError(f'unknown escape \\{e}')
                    else:
                        # literal source character contributes its UTF-8 bytes
                        raw.extend(s[i].encode('utf-8')); i+=1
                if i>=n: raise LangError('unterminated literal', span(st,sl,sc,i,line,col+(i-st)))
                i+=1; txt=s[st:i]; advance(txt)
                if quote=="'":
                    if len(raw)!=1: raise LangError('byte literal must encode exactly one byte', span(st,sl,sc,i,line,col))
                    out.append(Tok('BYTE',str(raw[0]),span(st,sl,sc,i,line,col),txt))
                else: out.append(Tok('STRING',bytes(raw).hex(),span(st,sl,sc,i,line,col),txt))
                continue
            matched=None
            for op in MULTI:
                if s.startswith(op,i): matched=op; break
            if matched:
                i+=len(matched); advance(matched); out.append(Tok(matched,matched,span(st,sl,sc,i,line,col))); continue
            if c in SINGLE:
                i+=1; advance(c); out.append(Tok(c,c,span(st,sl,sc,i,line,col))); continue
            raise LangError(f'unexpected character {c!r}',span(st,sl,sc,i+1,line,col+1))
        eof=Span(n,n,line,col,line,col); out.append(Tok('EOF','',eof)); return out

# ---------- AST / type model ----------

@dataclass
class N:
    kind: str
    a: tuple[Any,...]=()
    span: Span|None=None
    ty: Any=None

@dataclass(frozen=True)
class Ty:
    kind:str
    a:tuple[Any,...]=()
    def __str__(self):
        k=self.kind
        if k=='unit': return '()'
        if k=='name':
            q,args=self.a; base='.'.join(q)
            return base + (('['+', '.join(map(str,args))+']') if args else '')
        if k in ('opt','ref','array'):
            return {'opt':'?','ref':'ref ','array':'[]'}[k]+str(self.a[0])
        if k=='fn':
            ps,r=self.a; return 'fn('+', '.join(map(str,ps))+')'+('' if r.kind=='unit' else ' -> '+str(r))
        if k=='param': return self.a[0]
        return f'{k}{self.a}'

UNIT=Ty('unit')
def name_ty(n:str|tuple[str,...], args=()): return Ty('name',((n,) if isinstance(n,str) else tuple(n),tuple(args)))
def opt(t): return Ty('opt',(t,))
def ref(t): return Ty('ref',(t,))
def arr(t): return Ty('array',(t,))
def fnty(ps,r=UNIT): return Ty('fn',(tuple(ps),r))
def tparam(n): return Ty('param',(n,))

# ---------- parser ----------

ASSIGN={'=','+=','-=','*=','/=','%=','<<=','>>=','&=','|=','^='}
CMP={'==','!=','<','<=','>','>='}
PREC={'||':1,'&&':2,'==':3,'!=':3,'<':3,'<=':3,'>':3,'>=':3,'|':4,'^':5,'&':6,'<<':7,'>>':7,'+':8,'-':8,'*':9,'/':9,'%':9}

class Parser:
    def __init__(self,src:str):
        self.src=src; self.ts=[t for t in Lexer(src).lex() if t.kind!='COMMENT']; self.i=0
    def t(self,k=None):
        x=self.ts[self.i]; return x if k is None else x.kind==k
    def take(self,k=None):
        x=self.t()
        if k is not None and x.kind!=k: raise LangError(f'expected {k}, got {x.kind}',x.span)
        self.i+=1; return x
    def maybe(self,k):
        if self.t(k): return self.take()
        return None
    def node(self,k,*a,st=None,en=None):
        if st is None: st=self.ts[max(0,self.i-1)].span
        if en is None: en=self.ts[max(0,self.i-1)].span
        sp=Span(st.start,en.end,st.line,st.col,en.end_line,en.end_col) if st and en else None
        return N(k,tuple(a),sp)
    def program(self):
        ds=[]
        while not self.t('EOF'): ds.append(self.decl())
        return N('module',(tuple(ds),),Span(0,len(self.src),1,1,self.t().span.line,self.t().span.col))
    def qname(self):
        parts=[self.take('NAME').text]
        while self.maybe('.'): parts.append(self.take('NAME').text)
        return tuple(parts)
    def type_params(self):
        if not self.maybe('['): return ()
        xs=[]
        if not self.t(']'):
            while True:
                xs.append(self.take('NAME').text)
                if not self.maybe(','): break
                if self.t(']'): break
        self.take(']'); return tuple(xs)
    def comma_list(self,end,parse):
        xs=[]
        if self.t(end): return xs
        while True:
            xs.append(parse())
            if not self.maybe(','): break
            if self.t(end): break
        return xs
    def decl(self):
        st=self.t().span; public=bool(self.maybe('pub'))
        if self.maybe('import'):
            if public: raise LangError('imports cannot be pub',st)
            q=self.qname(); alias=None
            if self.maybe('as'): alias=self.take('NAME').text
            en=self.take(';').span; return self.node('import',q,alias,st=st,en=en)
        if self.maybe('const'):
            n=self.take('NAME').text; self.take(':'); ty=self.type(); self.take('='); e=self.expr(); en=self.take(';').span
            return self.node('const',public,n,ty,e,st=st,en=en)
        if self.maybe('struct'):
            n=self.take('NAME').text; gps=self.type_params(); self.take('{')
            def fld():
                fst=self.t().span; fp=bool(self.maybe('pub')); fn=self.take('NAME').text; self.take(':'); ft=self.type(); return (fp,fn,ft,fst)
            fs=self.comma_list('}',fld); en=self.take('}').span; return self.node('struct',public,n,gps,tuple(fs),st=st,en=en)
        if self.maybe('enum'):
            n=self.take('NAME').text; gps=self.type_params(); self.take('{')
            def var():
                v=self.take('NAME').text; payload=()
                if self.maybe('('): payload=tuple(self.comma_list(')',self.type)); self.take(')')
                return (v,payload)
            vs=self.comma_list('}',var); en=self.take('}').span; return self.node('enum',public,n,gps,tuple(vs),st=st,en=en)
        if self.maybe('fn'):
            n=self.take('NAME').text; gps=self.type_params(); ps=self.params(); rt=UNIT
            if self.maybe('->'): rt=self.type()
            body,en=self.block(); return self.node('fn',public,n,gps,tuple(ps),rt,tuple(body),st=st,en=en)
        raise LangError('expected declaration',self.t().span)
    def params(self):
        self.take('(')
        def one():
            n=self.take('NAME').text; self.take(':'); return (n,self.type())
        xs=self.comma_list(')',one); self.take(')'); return xs
    def type(self):
        if self.maybe('?'): return opt(self.type())
        if self.maybe('ref'): return ref(self.type())
        if self.maybe('['): self.take(']'); return arr(self.type())
        if self.maybe('('): self.take(')'); return UNIT
        if self.maybe('fn'):
            self.take('('); ps=self.comma_list(')',self.type); self.take(')'); rt=UNIT
            if self.maybe('->'):rt=self.type()
            return fnty(ps,rt)
        q=self.qname(); args=()
        if self.maybe('['): args=tuple(self.comma_list(']',self.type)); self.take(']')
        return name_ty(q,args)
    def block(self):
        self.take('{'); xs=[]
        while not self.t('}'): xs.append(self.stmt())
        en=self.take('}').span; return xs,en
    def stmt(self):
        st=self.t().span
        if self.maybe('var'):
            n=self.take('NAME').text; ty=None
            if self.maybe(':'): ty=self.type()
            self.take('='); e=self.expr(); en=self.take(';').span; return self.node('var',n,ty,e,st=st,en=en)
        if self.maybe('if'):
            self.take('('); c=self.condition(); self.take(')'); b,en=self.block(); eb=()
            if self.maybe('else'):
                if self.t('if'): eb=(self.stmt(),)
                else: eb,_=self.block(); eb=tuple(eb)
            return self.node('if',c,tuple(b),tuple(eb),st=st,en=en)
        if self.maybe('while'):
            self.take('('); c=self.condition(); self.take(')'); b,en=self.block(); return self.node('while',c,tuple(b),st=st,en=en)
        if self.maybe('for'):
            self.take('(')
            # array-only for-in: name in expr
            if self.t('NAME') and self.ts[self.i+1].kind=='in':
                n=self.take().text; self.take('in'); e=self.expr(); self.take(')'); b,en=self.block(); return self.node('forin',n,e,tuple(b),st=st,en=en)
            init=None; cond=None; step=None
            if not self.t(';'):
                if self.maybe('var'):
                    n=self.take('NAME').text; ty=None
                    if self.maybe(':'):ty=self.type()
                    self.take('='); e=self.expr(); init=N('var',(n,ty,e),st)
                else: init=self.assign_no_semi()
            self.take(';')
            if not self.t(';'): cond=self.condition()
            self.take(';')
            if not self.t(')'): step=self.assign_no_semi()
            self.take(')'); b,en=self.block(); return self.node('for',init,cond,step,tuple(b),st=st,en=en)
        if self.maybe('match'):
            self.take('('); e=self.expr(); self.take(')'); self.take('{'); arms=[]
            while not self.t('}'):
                p=self.pattern(); b,_=self.block(); arms.append((p,tuple(b)))
            en=self.take('}').span; return self.node('match',e,tuple(arms),st=st,en=en)
        if self.maybe('return'):
            e=None if self.t(';') else self.expr(); en=self.take(';').span; return self.node('return',e,st=st,en=en)
        if self.maybe('break'): en=self.take(';').span; return self.node('break',st=st,en=en)
        if self.maybe('continue'): en=self.take(';').span; return self.node('continue',st=st,en=en)
        if self.maybe('trap'): en=self.take(';').span; return self.node('trap',st=st,en=en)
        lhs=self.expr()
        if self.t().kind in ASSIGN:
            op=self.take().kind; rhs=self.expr(); en=self.take(';').span; return self.node('assign',lhs,op,rhs,st=st,en=en)
        en=self.take(';').span
        # checker further restricts expression statements to calls
        return self.node('exprstmt',lhs,st=st,en=en)
    def assign_no_semi(self):
        st=self.t().span; lhs=self.expr(); op=self.take().kind
        if op not in ASSIGN: raise LangError('expected assignment in for clause',self.ts[self.i-1].span)
        rhs=self.expr(); return self.node('assign',lhs,op,rhs,st=st,en=rhs.span)
    def condition(self):
        # `is` is parsed at comparison precedence by expr().  The checker allows
        # bindings only when the complete condition is an `is` node.
        return self.expr()
    def payload_pattern(self):
        """A v5 constructor payload pattern is intentionally only a binding or _.
        This keeps exhaustiveness first-order over the outer constructor.
        """
        st=self.t().span
        if self.t('NAME') and self.t().text=='_':
            self.take(); return self.node('p_wild',st=st)
        if self.t('NAME'):
            x=self.take(); return self.node('p_bind',x.text,st=st,en=x.span)
        raise LangError('pattern payload must be a name or _',self.t().span)
    def pattern(self):
        st=self.t().span
        if self.t('NAME') and self.t().text=='_': self.take(); return self.node('p_wild',st=st)
        if self.maybe('none'): return self.node('p_none',st=st)
        if self.maybe('some'):
            self.take('('); p=self.payload_pattern(); en=self.take(')').span; return self.node('p_some',p,st=st,en=en)
        if self.maybe('('): en=self.take(')').span; return self.node('p_unit',st=st,en=en)
        if self.maybe('true'): return self.node('p_bool',True,st=st)
        if self.maybe('false'): return self.node('p_bool',False,st=st)
        if self.t('INT'): x=self.take(); return self.node('p_int',x.text,st=st,en=x.span)
        if self.t('BYTE'): x=self.take(); return self.node('p_byte',int(x.text),st=st,en=x.span)
        if self.t('NAME'):
            q=self.qname(); ps=()
            if self.maybe('('): ps=tuple(self.comma_list(')',self.payload_pattern)); en=self.take(')').span
            else: en=self.ts[self.i-1].span
            # A payload-less one-segment name remains contextually either a binding
            # or a zero-payload enum variant; payloads themselves are never nested.
            return self.node('p_name',q,ps,st=st,en=en)
        raise LangError('expected pattern',self.t().span)
    def expr(self,minp=0):
        st=self.t().span
        # prefix
        if self.maybe('('):
            if self.maybe(')'): left=self.node('unit',st=st,en=self.ts[self.i-1].span)
            else: left=self.expr(); self.take(')')
        elif self.t('INT'): x=self.take(); left=self.node('int',x.text,st=st,en=x.span)
        elif self.t('FLOAT'): x=self.take(); left=self.node('float',x.text,st=st,en=x.span)
        elif self.t('BYTE'): x=self.take(); left=self.node('byte',int(x.text),st=st,en=x.span)
        elif self.t('STRING'): x=self.take(); left=self.node('string',bytes.fromhex(x.text),st=st,en=x.span)
        elif self.maybe('true'): left=self.node('bool',True,st=st)
        elif self.maybe('false'): left=self.node('bool',False,st=st)
        elif self.maybe('none'): left=self.node('none',st=st)
        elif self.maybe('some'):
            self.take('('); x=self.expr(); en=self.take(')').span; left=self.node('some',x,st=st,en=en)
        elif self.maybe('new'):
            x=self.expr(10); left=self.node('new',x,st=st,en=x.span)
        elif self.maybe('fn'):
            ps=self.params(); rt=UNIT
            if self.maybe('->'):rt=self.type()
            b,en=self.block(); left=self.node('anonfn',tuple(ps),rt,tuple(b),st=st,en=en)
        elif self.maybe('['):
            if self.maybe(']'): left=self.node('array',tuple(),st=st,en=self.ts[self.i-1].span)
            else:
                first=self.expr()
                if self.maybe(';'):
                    n=self.expr(); en=self.take(']').span; left=self.node('repeat',first,n,st=st,en=en)
                else:
                    xs=[first]
                    while self.maybe(','):
                        if self.t(']'):break
                        xs.append(self.expr())
                    en=self.take(']').span; left=self.node('array',tuple(xs),st=st,en=en)
        elif self.t('NAME'):
            q=self.qname(); left=self.node('qname',q,st=st,en=self.ts[self.i-1].span)
        elif self.t().kind in ('!','~','-','*'):
            opx=self.take().kind; x=self.expr(10); left=self.node('unary',opx,x,st=st,en=x.span)
        else: raise LangError('expected expression',self.t().span)
        # postfix: call, index, field, struct literal
        while True:
            if self.maybe('('):
                args=tuple(self.comma_list(')',self.expr)); en=self.take(')').span; left=self.node('call',left,args,st=st,en=en); continue
            if self.maybe('['):
                ix=self.expr(); en=self.take(']').span; left=self.node('index',left,ix,st=st,en=en); continue
            if self.maybe('.'):
                n=self.take('NAME'); left=self.node('field',left,n.text,st=st,en=n.span); continue
            if self.maybe('{'):
                fs=[]
                if not self.t('}'):
                    while True:
                        n=self.take('NAME').text; self.take(':'); x=self.expr(); fs.append((n,x))
                        if not self.maybe(','):break
                        if self.t('}'):break
                en=self.take('}').span; left=self.node('structlit',left,tuple(fs),st=st,en=en); continue
            break
        if self.maybe('as'):
            t=self.type(); left=self.node('cast',left,t,st=st,en=self.ts[self.i-1].span)
        used_cmp=False
        while (self.t().kind in PREC or self.t('is')):
            opx=self.t().kind; p=(3 if opx=='is' else PREC[opx])
            if p<minp:break
            if opx in CMP or opx=='is':
                if used_cmp: raise LangError('comparison / is operators do not chain',self.t().span)
                used_cmp=True
            self.take()
            if opx=='is':
                pat=self.pattern(); left=self.node('is',left,pat,st=st,en=pat.span)
            else:
                right=self.expr(p+1); left=self.node('binary',opx,left,right,st=st,en=right.span)
        return left

# ---------- static semantics ----------

PRIMS={'bool','i8','i16','i32','i64','u8','u16','u32','u64','f32','f64'}
INTS={f'{s}{w}':(w,s=='i') for s in ('i','u') for w in (8,16,32,64)}
FLOATS={'f32','f64'}

def int_info(t:Ty):
    if t.kind=='name' and not t.a[1] and len(t.a[0])==1:return INTS.get(t.a[0][0])
    return None

def is_prim(t,n): return t.kind=='name' and t.a==( (n,), () )
def substitute(t:Ty, m:dict[str,Ty])->Ty:
    if t.kind=='param': return m.get(t.a[0],t)
    if t.kind=='name':
        q,args=t.a; return Ty('name',(q,tuple(substitute(x,m) for x in args)))
    if t.kind in ('opt','ref','array'): return Ty(t.kind,(substitute(t.a[0],m),))
    if t.kind=='fn': return fnty([substitute(x,m) for x in t.a[0]], substitute(t.a[1],m))
    return t

def same(a:Ty,b:Ty): return a==b

def parse_int_text(s):
    q=s.replace('_','')
    if q.lower().startswith('0x'):return int(q,16)
    if q.lower().startswith('0b'):return int(q,2)
    return int(q,10)

def wrap_int(v:int,t:Ty):
    w,signed=int_info(t); m=1<<w; v%=m
    if signed and v >= 1<<(w-1):v-=m
    return v

def fround(v:float,t:Ty):
    if is_prim(t,'f32'):
        try:return struct.unpack('!f',struct.pack('!f',float(v)))[0]
        except OverflowError:return math.copysign(math.inf,v)
    return float(v)

def scalar_value(opx,a,b,t,fault=LangError):
    """Single normative scalar-operation implementation for the reference tools."""
    if opx=='==':return (a is b) if t.kind=='ref' else a==b
    if opx=='!=':return (a is not b) if t.kind=='ref' else a!=b
    if opx=='<':return a<b
    if opx=='<=':return a<=b
    if opx=='>':return a>b
    if opx=='>=':return a>=b
    if opx=='&&':return bool(a and b)
    if opx=='||':return bool(a or b)
    if opx in ('<<','>>'):
        w,_=int_info(t)
        if b<0 or b>=w:raise fault('invalid shift count')
        return wrap_int((a<<b) if opx=='<<' else (a>>b),t)
    if opx in ('&','|','^'):
        v={'&':lambda:a&b,'|':lambda:a|b,'^':lambda:a^b}[opx]();return wrap_int(v,t)
    if opx in ('+','-','*'):
        v={'+':lambda:a+b,'-':lambda:a-b,'*':lambda:a*b}[opx]();return wrap_int(v,t) if int_info(t) else fround(v,t)
    if opx=='/':
        if int_info(t):
            if b==0:raise fault('division by zero')
            q=abs(a)//abs(b);q=-q if (a<0)^(b<0) else q;return wrap_int(q,t)
        if b==0.0:
            if a==0.0:return math.nan
            sign=math.copysign(1.0,a)*math.copysign(1.0,b)
            return math.copysign(math.inf,sign)
        return fround(a/b,t)
    if opx=='%':
        if b==0:raise fault('remainder by zero')
        q=abs(a)//abs(b);q=-q if (a<0)^(b<0) else q;return wrap_int(a-q*b,t)
    raise fault('bad scalar operator '+opx)

@dataclass
class StructInfo:
    public:bool; name:str; gps:tuple[str,...]; fields:tuple[tuple[bool,str,Ty,Span],...]; owner:tuple[str,...]
@dataclass
class EnumInfo:
    public:bool; name:str; gps:tuple[str,...]; variants:tuple[tuple[str,tuple[Ty,...]],...]; owner:tuple[str,...]
@dataclass
class FnInfo:
    public:bool; name:str; gps:tuple[str,...]; params:tuple[tuple[str,Ty],...]; ret:Ty; body:tuple[N,...]; node:N
@dataclass
class ConstInfo:
    public:bool; name:str; ty:Ty; expr:N; value:Any=None; state:int=0

class Checker:
    def __init__(self,mod:N,module_name=('main',),imports:dict[tuple[str,...],'CheckedModule']|None=None,host_modules:dict|None=None):
        self.mod=mod; self.module_name=tuple(module_name); self.import_modules=imports or {}; self.host_modules=host_modules or {}
        self.structs={}; self.enums={}; self.funcs={}; self.consts={}; self.imports={}
        self.top=set(); self.scopes=[]; self.gparams:set[str]=set(); self.ret=UNIT; self.loop=0; self.current_fn=None
        self.expr_types={}; self.place_types={}; self.anon_types={}; self.current_origin=self.module_name; self.source_reserved=set()
        self.builtins={'len','push','pop','splice'}
        self.collect()
    def err(self,msg,node=None):
        e=LangError(msg, node.span if isinstance(node,N) else node); e.module=tuple(self.current_origin); raise e
    def claim(self,n,node=None):
        if n in self.top or n in self.builtins:self.err(f'duplicate or reserved module name {n}',node)
        self.top.add(n)
    def collect(self):
        for d in self.mod.a[0]:
            k=d.kind
            if k=='import':
                q,alias=d.a; n=alias or q[-1]; self.claim(n,d); self.imports[n]=q
            elif k=='struct':
                public,n,gps,fs=d.a; self.claim(n,d); self._unique(gps,'generic parameter',d); self._unique([x[1] for x in fs],'field',d)
                self.structs[n]=StructInfo(public,n,gps,fs,tuple(getattr(d,'origin',self.module_name)))
            elif k=='enum':
                public,n,gps,vs=d.a; self.claim(n,d); self._unique(gps,'generic parameter',d); self._unique([x[0] for x in vs],'variant',d)
                self.enums[n]=EnumInfo(public,n,gps,vs,tuple(getattr(d,'origin',self.module_name)))
            elif k=='fn':
                public,n,gps,ps,rt,b=d.a; self.claim(n,d); self._unique(gps,'generic parameter',d); self._unique([x[0] for x in ps],'parameter',d)
                self.funcs[n]=FnInfo(public,n,gps,ps,rt,b,d)
            elif k=='const':
                public,n,t,e=d.a; self.claim(n,d); self.consts[n]=ConstInfo(public,n,t,e)
    def _unique(self,xs,what,node):
        if len(xs)!=len(set(xs)):self.err(f'duplicate {what}',node)
    def checked(self):
        # declarations/types
        for s in self.structs.values():
            self.gparams=set(s.gps)
            for _,_,t,_ in s.fields:self.resolve_ty(t)
        for e in self.enums.values():
            self.gparams=set(e.gps)
            for _,ts in e.variants:
                for t in ts:self.resolve_ty(t)
        self.gparams=set(); self.validate_layouts()
        for c in self.consts.values(): c.ty=self.resolve_ty(c.ty)
        for f in self.funcs.values():
            self.gparams=set(f.gps); f.params=tuple((n,self.resolve_ty(t)) for n,t in f.params); f.ret=self.resolve_ty(f.ret)
        self.gparams=set()
        # generic recursion restriction
        self.check_generic_recursion()
        # constants then bodies
        for n in self.consts:self.eval_const(n)
        for f in self.funcs.values():self.check_fn(f)
        return CheckedModule(self)
    def resolve_ty(self,t:Ty)->Ty:
        if t.kind=='unit':return t
        if t.kind in ('opt','ref','array'):return Ty(t.kind,(self.resolve_ty(t.a[0]),))
        if t.kind=='fn':return fnty([self.resolve_ty(x) for x in t.a[0]],self.resolve_ty(t.a[1]))
        if t.kind!='name':return t
        q,args=t.a
        if len(q)==1 and q[0] in self.gparams:
            if args:self.err(f'type parameter {q[0]} cannot have type arguments')
            return tparam(q[0])
        args=tuple(self.resolve_ty(x) for x in args)
        if len(q)==1 and q[0] in PRIMS:
            if args:self.err(f'primitive {q[0]} takes no type arguments')
            return Ty('name',(q,()))
        if len(q)==1 and q[0] in self.structs:
            need=len(self.structs[q[0]].gps)
            if len(args)!=need:self.err(f'{q[0]} expects {need} type arguments, got {len(args)}')
            return Ty('name',(q,args))
        if len(q)==1 and q[0] in self.enums:
            need=len(self.enums[q[0]].gps)
            if len(args)!=need:self.err(f'{q[0]} expects {need} type arguments, got {len(args)}')
            return Ty('name',(q,args))
        if len(q)>=2 and q[0] in self.imports:
            target=self.imports[q[0]]; hm=self.host_modules.get(target)
            if hm is not None:return hm.resolve_type(q[1:],args)
        if len(q)>=2:return Ty('name',(q,args))
        self.err(f'unknown type {".".join(q)}')
    def validate_layouts(self):
        # Constructor-level cycle check. ref/array break storage recursion; opt/unit/fn do not introduce storage indirection.
        graph={n:set() for n in self.structs|self.enums}
        def walk(owner,t,gps):
            old=self.gparams; self.gparams=set(gps)
            try:t=self.resolve_ty(t)
            finally:self.gparams=old
            if t.kind in ('ref','array','fn','unit','param'):return
            if t.kind=='opt':return walk(owner,t.a[0],gps)
            if t.kind=='name' and len(t.a[0])==1 and t.a[0][0] in graph:graph[owner].add(t.a[0][0])
        for n,s in self.structs.items():
            for _,_,t,_ in s.fields:walk(n,t,s.gps)
        for n,e in self.enums.items():
            for _,ts in e.variants:
                for t in ts:walk(n,t,e.gps)
        state={}
        def dfs(n,path):
            state[n]=1
            for m in graph[n]:
                if state.get(m)==1:self.err('infinitely-sized recursive value type: '+' -> '.join(path+[m]))
                if not state.get(m):dfs(m,path+[m])
            state[n]=2
        for n in graph:
            if not state.get(n):dfs(n,[n])
    def check_generic_recursion(self):
        # Approximation on source call graph, sufficient for explicit self/mutual references. Calls through fn values aren't generic polymorphic calls.
        generic={n for n,f in self.funcs.items() if f.gps}
        edges={n:set() for n in generic}
        calls={n:[] for n in generic}
        def visit(n,owner):
            if not isinstance(n,N):return
            if n.kind=='call':
                cal=n.a[0]
                if cal.kind=='qname' and len(cal.a[0])==1 and cal.a[0][0] in generic:
                    edges[owner].add(cal.a[0][0]); calls[owner].append((cal.a[0][0],n))
            for x in n.a:
                if isinstance(x,N):visit(x,owner)
                elif isinstance(x,(tuple,list)):
                    for y in x:
                        if isinstance(y,N):visit(y,owner)
                        elif isinstance(y,tuple):
                            for z in y:
                                if isinstance(z,N):visit(z,owner)
        for name in generic:
            for s in self.funcs[name].body:visit(s,name)
        # Tarjan SCC
        idx=0; stack=[]; on=set(); ind={}; low={}
        def strong(v):
            nonlocal idx
            ind[v]=low[v]=idx; idx+=1; stack.append(v); on.add(v)
            for w in edges[v]:
                if w not in ind:strong(w); low[v]=min(low[v],low[w])
                elif w in on:low[v]=min(low[v],ind[w])
            if low[v]==ind[v]:
                comp=[]
                while True:
                    w=stack.pop(); on.remove(w); comp.append(w)
                    if w==v:break
                if len(comp)>1:self.err('mutually recursive generic functions are not allowed: '+', '.join(sorted(comp)))
        for v in generic:
            if v not in ind:strong(v)
        # Exact self recursion is naturally guaranteed later by inference: we additionally reject obvious source calls where args structurally change params.
        # Full rule is checked at call sites while body is typechecked.
    def push(self):self.scopes.append({})
    def pop(self):self.scopes.pop()
    def bind(self,n,t,node=None):
        if n=='_':self.err('_ cannot be a variable name',node)
        if n in self.top or n in self.builtins or n in self.source_reserved or n in self.gparams or any(n in s for s in self.scopes):self.err(f'name {n} would shadow an existing name',node)
        self.scopes[-1][n]=t
    def lookup_local(self,n):
        for s in reversed(self.scopes):
            if n in s:return s[n]
        return None
    def check_fn(self,f:FnInfo):
        self.source_reserved=set(getattr(f.node,'reserved',()))
        if set(f.gps)&self.source_reserved:self.err(f'generic parameter shadows a module name: {sorted(set(f.gps)&self.source_reserved)}',f.node)
        self.gparams=set(f.gps); self.ret=f.ret; self.current_fn=f; self.current_origin=getattr(f.node,'origin',self.module_name); self.loop=0; self.scopes=[]; self.push()
        for n,t in f.params:self.bind(n,t,f.node)
        self.block(f.body,new=False)
        if f.ret!=UNIT and not self.block_returns(f.body):self.err(f'function {f.name} may fall off the end',f.node)
        self.pop(); self.gparams=set(); self.current_fn=None; self.source_reserved=set()
    def block_returns(self,ss):
        for s in ss:
            if self.stmt_returns(s):return True
        return False
    def contains_break(self,ss):
        for s in ss:
            if s.kind=='break':return True
            if s.kind in ('if','while','for','forin'):
                for x in s.a:
                    if isinstance(x,tuple) and x and all(isinstance(y,N) for y in x) and self.contains_break(x):return True
            if s.kind=='match':
                if any(self.contains_break(b) for _,b in s.a[1]):return True
        return False
    def stmt_returns(self,s):
        if s.kind in ('return','trap'):return True
        if s.kind=='if':return bool(s.a[2]) and self.block_returns(s.a[1]) and self.block_returns(s.a[2])
        if s.kind=='match':return bool(s.a[1]) and all(self.block_returns(b) for _,b in s.a[1])
        if s.kind=='while' and s.a[0].kind=='bool' and s.a[0].a[0] is True and not self.contains_break(s.a[1]):return True
        return False
    def block(self,ss,new=True):
        if new:self.push()
        for s in ss:self.stmt(s)
        if new:self.pop()
    def stmt(self,s):
        k=s.kind
        if k=='var':
            n,t,e=s.a
            if t is not None:
                t=self.resolve_ty(t); et=self.expr(e,t); self.req(t,et,s)
            else:
                et=self.expr(e); t=et
                if self.is_ambiguous_value(e):self.err('initializer is ambiguous; add a type annotation',s)
            self.bind(n,t,s); return
        if k=='assign':
            l,opx,r=s.a; lt=self.place(l); l.ty=lt; rhs_expected = (name_ty('u64') if opx in ('<<=','>>=') else lt); rt=self.expr(r, rhs_expected)
            if opx=='=':self.req(lt,rt,s)
            else:self.binop(opx[:-1],lt,rt,s)
            return
        if k=='exprstmt':
            if s.a[0].kind!='call':self.err('only calls may be expression statements',s)
            self.expr(s.a[0]); return
        if k=='if':
            binds=self.condition(s.a[0]); self.push(); self.bindings(binds,s); self.block(s.a[1],False); self.pop(); self.block(s.a[2]); return
        if k=='while':
            binds=self.condition(s.a[0]); self.loop+=1; self.push(); self.bindings(binds,s); self.block(s.a[1],False); self.pop(); self.loop-=1; return
        if k=='for':
            init,c,step,b=s.a; self.push(); self.loop+=1
            if init:self.stmt(init)
            if c:
                binds=self.condition(c)
                if binds:self.err('for condition may not bind a pattern',c)
            if step:self.stmt(step)
            self.block(b); self.loop-=1; self.pop(); return
        if k=='forin':
            n,e,b=s.a; at=self.expr(e)
            if at.kind!='array':self.err('for-in requires []T',e)
            self.push(); self.loop+=1; self.bind(n,at.a[0],s); self.block(b,False); self.loop-=1; self.pop(); return
        if k=='match':
            st=self.expr(s.a[0]); seen=[]; wildcard=False
            for p,b in s.a[1]:
                binds,key=self.pattern(p,st)
                if key=='_':wildcard=True
                elif key in seen:self.err(f'duplicate match arm {key}',p)
                seen.append(key); self.push(); self.bindings(binds,p); self.block(b,False); self.pop()
            if not wildcard:self.check_exhaustive(st,seen,s)
            return
        if k=='return':
            e=s.a[0]
            if e is None:self.req(UNIT,self.ret,s)
            else:self.req(self.ret,self.expr(e,self.ret),s)
            return
        if k in ('break','continue'):
            if not self.loop:self.err(f'{k} outside loop',s)
            return
        if k=='trap':return
        self.err(f'unhandled statement {k}',s)
    def bindings(self,b,node):
        for n,t in b.items():self.bind(n,t,node)
    def condition(self,c):
        if c.kind=='is':
            t=self.expr(c.a[0]); b,_=self.pattern(c.a[1],t); return b
        self.req(name_ty('bool'),self.expr(c,name_ty('bool')),c); return {}
    def pattern(self,p,t:Ty):
        p.subject_ty=t
        k=p.kind
        if k=='p_wild':return {},'_'
        if k=='p_bind':return {p.a[0]:t},'_'
        if k=='p_unit':self.req(UNIT,t,p); return {},'()'
        if k=='p_none':
            if t.kind!='opt':self.err('none pattern requires ?T',p)
            return {},'none'
        if k=='p_some':
            if t.kind!='opt':self.err('some pattern requires ?T',p)
            b=self.payload_binding(p.a[0],t.a[0]); return b,'some'
        if k=='p_bool':self.req(name_ty('bool'),t,p); return {},str(p.a[0]).lower()
        if k=='p_int':
            if not int_info(t):self.err('integer pattern requires integer subject',p)
            return {},('int',parse_int_text(p.a[0]))
        if k=='p_byte':self.req(name_ty('u8'),t,p);return {},('byte',p.a[0])
        if k=='p_name':
            q,subs=p.a
            # A plain one-segment name with no payload is a binding unless it
            # resolves to a zero-payload enum variant.
            if len(q)==1 and not subs:
                variant=self._variant_for_pattern(q,t)
                if variant is None:return {q[0]:t},'_'
            variant=self._variant_for_pattern(q,t)
            if variant is None:self.err('pattern name is neither binding nor matching enum variant',p)
            en,v,ts=variant
            if len(ts)!=len(subs):self.err(f'{en}.{v} pattern expects {len(ts)} payloads',p)
            binds={}
            for sp,pt in zip(subs,ts):
                b=self.payload_binding(sp,pt)
                if set(b)&set(binds):self.err('duplicate binding in pattern',p)
                binds.update(b)
            return binds,(en,v)
        self.err('unsupported pattern',p)
    def payload_binding(self,p,t):
        if p.kind=='p_wild':return {}
        if p.kind=='p_bind':return {p.a[0]:t}
        self.err('nested destructuring patterns are not supported in v5',p)
    def _variant_for_pattern(self,q,t):
        if t.kind!='name' or len(t.a[0])!=1:return None
        en=t.a[0][0]
        if en not in self.enums:return None
        info=self.enums[en]; m=dict(zip(info.gps,t.a[1])); variants=dict(info.variants)
        if len(q)==1:v=q[0]
        elif len(q)==2 and q[0]==en:v=q[1]
        else:return None
        if v not in variants:return None
        return en,v,tuple(substitute(self._resolved_decl_ty(x,info.gps),m) for x in variants[v])
    def check_exhaustive(self,t,seen,node):
        keys=set(seen)
        if t==UNIT:
            if '()' not in keys:self.err('non-exhaustive match: missing ()',node)
            return
        if is_prim(t,'bool'):
            miss={'true','false'}-keys
            if miss:self.err('non-exhaustive match: missing '+', '.join(sorted(miss)),node)
            return
        if t.kind=='opt':
            miss={'none','some'}-keys
            if miss:self.err('non-exhaustive match: missing '+', '.join(sorted(miss)),node)
            return
        if t.kind=='name' and len(t.a[0])==1 and t.a[0][0] in self.enums:
            en=t.a[0][0]; needed={(en,v) for v,_ in self.enums[en].variants};miss=needed-keys
            if miss:self.err('non-exhaustive match: missing '+', '.join(v for _,v in sorted(miss)),node)
            return
        self.err('non-exhaustive match over an open value domain requires _ or a binding arm',node)
    def is_ambiguous_value(self,e): return e.kind in ('none','array') and (e.kind!='array' or not e.a[0])
    def req(self,a,b,node=None):
        if a!=b:self.err(f'type mismatch: expected {a}, got {b}',node)
    def expr(self,e:N,expected:Ty|None=None)->Ty:
        k=e.kind
        if k=='unit':t=UNIT
        elif k=='bool':t=name_ty('bool')
        elif k=='byte':t=name_ty('u8')
        elif k=='string':t=arr(name_ty('u8'))
        elif k=='int':
            v=parse_int_text(e.a[0])
            if expected and int_info(expected):
                w,s=int_info(expected); lo=-(1<<(w-1)) if s else 0; hi=(1<<(w-1))-1 if s else (1<<w)-1
                if not(lo<=v<=hi):self.err(f'integer literal {v} does not fit {expected}',e)
                t=expected
            else:t=name_ty('i64')
        elif k=='float':
            t=expected if expected and expected.kind=='name' and expected.a[0][0] in FLOATS else name_ty('f64')
            v=float(e.a[0].replace('_',''))
            if not math.isfinite(v) or not math.isfinite(fround(v,t)):self.err(f'float literal out of finite range for {t}',e)
        elif k=='none':
            if not expected or expected.kind!='opt':self.err('none requires expected ?T',e)
            t=expected
        elif k=='some':
            ie=expected.a[0] if expected and expected.kind=='opt' else None; it=self.expr(e.a[0],ie); t=opt(it)
        elif k=='qname':t=self.qname_expr(e.a[0],e,expected)
        elif k=='array':
            xs=e.a[0]
            elem=expected.a[0] if expected and expected.kind=='array' else (self.expr(xs[0]) if xs else None)
            if elem is None:self.err('empty array requires expected []T',e)
            for x in xs:self.req(elem,self.expr(x,elem),x)
            t=arr(elem)
        elif k=='repeat':
            x,n=e.a; elem=expected.a[0] if expected and expected.kind=='array' else self.expr(x); self.req(elem,self.expr(x,elem),x); self.req(name_ty('u64'),self.expr(n,name_ty('u64')),n); t=arr(elem)
        elif k=='unary':
            opx,x=e.a
            if opx=='*':
                xt=self.expr(x)
                if xt.kind!='ref':self.err('* requires ref T',e)
                t=xt.a[0]
            else:
                # A negative minimum signed literal (e.g. -128:i8) must be accepted even
                # though its positive magnitude is not itself representable as i8.
                if opx=='-' and x.kind=='int' and expected and int_info(expected) and int_info(expected)[1]:
                    w,_=int_info(expected); mag=parse_int_text(x.a[0])
                    if mag<0 or mag>(1<<(w-1)):self.err(f'negative integer literal -{mag} does not fit {expected}',e)
                    x.ty=expected; self.expr_types[id(x)]=expected; xt=expected
                else:
                    xt=self.expr(x, expected if expected and (int_info(expected) or expected.kind=='name' and expected.a[0][0] in FLOATS) else None)
                if opx=='!':self.req(name_ty('bool'),xt,e);t=xt
                elif opx=='~':
                    if not int_info(xt):self.err('~ requires integer',e)
                    t=xt
                elif opx=='-':
                    if not(int_info(xt) or (xt.kind=='name' and xt.a[0][0] in FLOATS)):self.err('- requires numeric',e)
                    t=xt
        elif k=='is':
            subject,pat=e.a; st=self.expr(subject); binds,_=self.pattern(pat,st)
            if binds:self.err('a binding `is` pattern is only allowed as the complete if/while condition',e)
            t=name_ty('bool')
        elif k=='binary':
            opx,l,r=e.a
            num_expected=expected if expected and (int_info(expected) or expected.kind=='name' and expected.a[0][0] in FLOATS) else None
            def contextual_numeric(x):
                return x.kind in ('int','float') or (x.kind=='unary' and x.a[0]=='-' and x.a[1].kind in ('int','float'))
            if opx in ('<<','>>'):
                # Shift result/LHS determines width; RHS is uniformly u64.
                lt=self.expr(l,num_expected)
                rt=self.expr(r,name_ty('u64'))
            elif num_expected is not None:
                lt=self.expr(l,num_expected); rt=self.expr(r,num_expected)
            elif contextual_numeric(l) and not contextual_numeric(r):
                # Static typing is not evaluation: inspect the non-literal side first
                # so `1 + x` is as predictable as `x + 1`.
                rt=self.expr(r); lt=self.expr(l,rt)
            else:
                lt=self.expr(l); rt=self.expr(r,lt)
            t=self.binop(opx,lt,rt,e)
        elif k=='cast':
            x,to=e.a; to=self.resolve_ty(to); fr=self.expr(x); self.check_cast(fr,to,e); t=to
        elif k=='new':
            inner_expected=expected.a[0] if expected and expected.kind=='ref' else None
            t=ref(self.expr(e.a[0],inner_expected))
        elif k=='index':
            a,ix=e.a; at=self.expr(a)
            if at.kind!='array':self.err('indexing requires []T',e)
            self.req(name_ty('u64'),self.expr(ix,name_ty('u64')),ix); t=at.a[0]
        elif k=='field':
            # parser mostly folds dotted chains into qname; kept for completeness
            bt=self.expr(e.a[0]); t=self.field_type(bt,e.a[1],e)
        elif k=='structlit':t=self.struct_lit(e,expected)
        elif k=='call':t=self.call_type(e,expected)
        elif k=='anonfn':t=self.anon_type(e,expected)
        else:self.err(f'unhandled expression {k}',e)
        e.ty=t; self.expr_types[id(e)]=t
        if expected is not None:self.req(expected,t,e)
        return t
    def qname_expr(self,q,node,expected=None):
        first=q[0]; t=self.lookup_local(first)
        if t is not None:
            for f in q[1:]:t=self.field_type(t,f,node)
            return t
        if len(q)==1 and first in self.consts:return self.consts[first].ty
        if len(q)==1 and first in self.funcs:
            f=self.funcs[first]
            if f.gps:self.err(f'generic function {first} is not a first-class value',node)
            return fnty([t for _,t in f.params],f.ret)
        # zero-payload enum variant, possibly generic inferred from expected
        v=self.resolve_variant_qname(q,expected,())
        if v is not None:
            et,_,_=v
            node.resolved_variant=(et,q[-1])
            return et
        # imported/host member expression
        if first in self.imports:
            return self.external_member_type(first,q[1:],node)
        self.err(f'unknown value {".".join(q)}',node)
    def field_type(self,t:Ty,name,node):
        base=t.a[0] if t.kind=='ref' else t
        if base.kind!='name' or len(base.a[0])!=1 or base.a[0][0] not in self.structs:self.err(f'{t} has no field {name}',node)
        s=self.structs[base.a[0][0]]; fs={n:(pub,ty) for pub,n,ty,_ in s.fields}
        if name not in fs:self.err(f'{s.name} has no field {name}',node)
        pub,fty=fs[name]
        owner=s.owner
        if not pub and self.current_origin!=owner:self.err(f'field {name} of {s.name} is private',node)
        return substitute(self._resolved_decl_ty(fty,s.gps),dict(zip(s.gps,base.a[1])))
    def struct_lit(self,e,expected):
        cal,fields=e.a
        if cal.kind!='qname' or len(cal.a[0])!=1:self.err('struct literal requires struct name',e)
        n=cal.a[0][0]
        if n not in self.structs:self.err(f'{n} is not a struct',e)
        s=self.structs[n]; supplied={};
        for fn,x in fields:
            if fn in supplied:self.err(f'duplicate struct literal field {fn}',e)
            supplied[fn]=x
        declared={fn:t for _,fn,t,_ in s.fields}
        owner=s.owner
        if self.current_origin!=owner:
            private=[fn for fp,fn,_,_ in s.fields if not fp]
            if private:self.err(f'cannot construct {n} outside its module because it has private fields',e)
        if set(supplied)!=set(declared):self.err(f'struct literal fields for {n} must be exactly {sorted(declared)}',e)
        m={}
        if expected and expected.kind=='name' and expected.a[0]==(n,) and len(expected.a[1])==len(s.gps):m.update(zip(s.gps,expected.a[1]))
        # infer type params from field values where possible
        for fn,tmpl in declared.items():
            tmpl=self._resolved_decl_ty(tmpl,s.gps)
            at=self.expr(supplied[fn], substitute(tmpl,m) if self.is_fully_bound(tmpl,m) else None)
            self.unify(tmpl,at,m,e)
        if set(m)!=set(s.gps):self.err(f'cannot infer type arguments for {n}; add an expected type',e)
        actual=name_ty(n,[m[g] for g in s.gps])
        for fn,tmpl in declared.items():self.req(substitute(self._resolved_decl_ty(tmpl,s.gps),m),self.expr(supplied[fn],substitute(self._resolved_decl_ty(tmpl,s.gps),m)),supplied[fn])
        return actual
    def _resolved_decl_ty(self,t,gps):
        old=self.gparams;self.gparams=set(gps)
        try:return self.resolve_ty(t)
        finally:self.gparams=old
    def call_type(self,e,expected):
        cal,args=e.a
        # builtins
        if cal.kind=='qname' and len(cal.a[0])==1 and cal.a[0][0] in self.builtins:
            n=cal.a[0][0]
            if n=='len':
                if len(args)!=1:self.err('len expects one argument',e)
                at=self.expr(args[0]);
                if at.kind!='array':self.err('len expects []T',args[0])
                return name_ty('u64')
            if n=='push':
                if len(args)!=2:self.err('push expects two arguments',e)
                at=self.expr(args[0]);
                if at.kind!='array':self.err('push first argument must be []T',args[0])
                self.req(at.a[0],self.expr(args[1],at.a[0]),args[1]);return UNIT
            if n=='pop':
                if len(args)!=1:self.err('pop expects one argument',e)
                at=self.expr(args[0]);
                if at.kind!='array':self.err('pop expects []T',args[0])
                return at.a[0]
            if n=='splice':
                if len(args)!=4:self.err('splice expects array, start, end, replacement',e)
                at=self.expr(args[0]);
                if at.kind!='array':self.err('splice first argument must be []T',args[0])
                self.req(name_ty('u64'),self.expr(args[1],name_ty('u64')),args[1])
                self.req(name_ty('u64'),self.expr(args[2],name_ty('u64')),args[2])
                self.req(at,self.expr(args[3],at),args[3])
                return UNIT
        # named source function, generic or not
        if cal.kind=='qname' and len(cal.a[0])==1 and cal.a[0][0] in self.funcs:
            f=self.funcs[cal.a[0][0]]; return self.instantiate_call(f,args,expected,e)
        # enum constructor
        if cal.kind=='qname':
            v=self.resolve_variant_qname(cal.a[0],expected,args)
            if v is not None:
                et,pts,m=v
                if len(pts)!=len(args):self.err(f'enum constructor expects {len(pts)} arguments',e)
                for p,a in zip(pts,args):self.req(p,self.expr(a,p),a)
                e.resolved_variant=(et,cal.a[0][-1])
                return et
        # ordinary function value (including struct field / anon fn)
        ct=self.expr(cal)
        if ct.kind!='fn':self.err(f'called value has type {ct}, not a function',cal)
        ps,r=ct.a
        if len(ps)!=len(args):self.err(f'function expects {len(ps)} arguments, got {len(args)}',e)
        for p,a in zip(ps,args):self.req(p,self.expr(a,p),a)
        return r
    def instantiate_call(self,f:FnInfo,args,expected,node):
        if len(args)!=len(f.params):self.err(f'{f.name} expects {len(f.params)} arguments, got {len(args)}',node)
        if not f.gps:
            for (_,p),a in zip(f.params,args):self.req(p,self.expr(a,p),a)
            return f.ret
        m={}
        if expected:self.unify(f.ret,expected,m,node,soft=True)
        # initial argument types, using substituted expected patterns where fully bound
        for (_,p),a in zip(f.params,args):
            ep=substitute(p,m) if self.is_fully_bound(p,m) else None
            at=self.expr(a,ep)
            self.unify(p,at,m,node)
        if set(m)!=set(f.gps):self.err(f'cannot infer generic arguments for {f.name}',node)
        node.generic_args=tuple(m[g] for g in f.gps)
        for (_,p),a in zip(f.params,args):self.req(substitute(p,m),self.expr(a,substitute(p,m)),a)
        # direct recursive generic call must preserve exact type params
        if self.current_fn is f:
            for gp in f.gps:
                if m[gp]!=tparam(gp):self.err(f'recursive generic call to {f.name} changes type parameter {gp}',node)
        return substitute(f.ret,m)
    def is_fully_bound(self,t,m):
        if t.kind=='param':return t.a[0] in m
        if t.kind=='name':return all(self.is_fully_bound(x,m) for x in t.a[1])
        if t.kind in ('opt','ref','array'):return self.is_fully_bound(t.a[0],m)
        if t.kind=='fn':return all(self.is_fully_bound(x,m) for x in t.a[0]) and self.is_fully_bound(t.a[1],m)
        return True
    def unify(self,p:Ty,a:Ty,m,node,soft=False):
        if p.kind=='param':
            n=p.a[0]
            if n in m and m[n]!=a:
                if soft:return False
                self.err(f'conflicting generic inference for {n}: {m[n]} vs {a}',node)
            m[n]=a;return True
        if p.kind!=a.kind:
            if soft:return False
            self.err(f'cannot match generic parameter type {p} with {a}',node)
        if p.kind=='name':
            if p.a[0]!=a.a[0] or len(p.a[1])!=len(a.a[1]):
                if soft:return False
                self.err(f'cannot match {p} with {a}',node)
            return all(self.unify(x,y,m,node,soft) for x,y in zip(p.a[1],a.a[1]))
        if p.kind in ('opt','ref','array'):return self.unify(p.a[0],a.a[0],m,node,soft)
        if p.kind=='fn':
            if len(p.a[0])!=len(a.a[0]):
                if soft:return False
                self.err('function arity differs during generic inference',node)
            ok=all(self.unify(x,y,m,node,soft) for x,y in zip(p.a[0],a.a[0])); return self.unify(p.a[1],a.a[1],m,node,soft) and ok
        return True
    def resolve_variant_qname(self,q,expected,args):
        if len(q)!=2 or q[0] not in self.enums:return None
        en,v=q; info=self.enums[en]; variants=dict(info.variants)
        if v not in variants:return None
        pts=tuple(self._resolved_decl_ty(x,info.gps) for x in variants[v]); m={}
        if expected and expected.kind=='name' and expected.a[0]==(en,) and len(expected.a[1])==len(info.gps):m.update(zip(info.gps,expected.a[1]))
        if args:
            if len(args)!=len(pts):self.err(f'{en}.{v} expects {len(pts)} payloads')
            for p,a in zip(pts,args):
                ep=substitute(p,m) if self.is_fully_bound(p,m) else None
                at=self.expr(a,ep);self.unify(p,at,m,a)
        if set(m)!=set(info.gps):
            if info.gps:return None
        et=name_ty(en,[m[g] for g in info.gps]); return et,tuple(substitute(x,m) for x in pts),m
    def anon_type(self,e,expected):
        ps,rt,b=e.a; old_scopes=self.scopes; old_ret=self.ret; old_fn=self.current_fn; old_reserved=self.source_reserved
        # no runtime capture, and no shadowing of enclosing runtime names either.
        outer_names={n for scope in old_scopes for n in scope}
        self.source_reserved=set(old_reserved)|outer_names
        self.scopes=[];self.push(); self.ret=self.resolve_ty(rt)
        rps=[]
        for n,t in ps:
            t=self.resolve_ty(t);rps.append(t);self.bind(n,t,e)
        self.block(b,False)
        if self.ret!=UNIT and not self.block_returns(b):self.err('anonymous function may fall off end',e)
        self.pop();self.scopes=old_scopes;self.ret=old_ret;self.current_fn=old_fn;self.source_reserved=old_reserved
        t=fnty(rps,self.resolve_ty(rt)); self.anon_types[id(e)]=t;return t
    def fieldless_enum(self,t):
        if t.kind!='name' or len(t.a[0])!=1:return False
        info=self.enums.get(t.a[0][0])
        return info is not None and all(len(payload)==0 for _,payload in info.variants)
    def binop(self,opx,l,r,node):
        if opx in ('&&','||'):
            self.req(name_ty('bool'),l,node);self.req(l,r,node);return l
        if opx in CMP:
            self.req(l,r,node)
            if opx in ('<','<=','>','>=') and not(int_info(l) or (l.kind=='name' and l.a[0][0] in FLOATS)):self.err('ordering only supports numeric types',node)
            if opx in ('==','!='):
                ok=is_prim(l,'bool') or int_info(l) or (l.kind=='name' and l.a[0][0] in FLOATS) or l.kind=='ref' or self.fieldless_enum(l)
                if not ok:self.err(f'equality is not defined for {l}',node)
            return name_ty('bool')
        if opx in ('<<','>>'):
            if not int_info(l):self.err('shift left operand must be integer',node)
            self.req(name_ty('u64'),r,node);return l
        if opx in ('&','|','^'):
            if not int_info(l):self.err('bitwise operator requires integers',node)
            self.req(l,r,node);return l
        if opx in ('+','-','*','/','%'):
            if not(int_info(l) or (l.kind=='name' and l.a[0][0] in FLOATS)):self.err('arithmetic requires numeric type',node)
            if opx=='%' and l.kind=='name' and l.a[0][0] in FLOATS:self.err('% is integer-only',node)
            self.req(l,r,node);return l
        self.err(f'unknown operator {opx}',node)
    def check_cast(self,a,b,node):
        anum=int_info(a) or (a.kind=='name' and a.a[0][0] in FLOATS)
        bnum=int_info(b) or (b.kind=='name' and b.a[0][0] in FLOATS)
        if not(anum and bnum):self.err(f'cannot cast {a} to {b}',node)
    def place(self,e):
        if e.kind=='qname':
            q=e.a[0]; t=self.lookup_local(q[0])
            if t is None:self.err('assignment target must start with a local variable',e)
            for f in q[1:]:t=self.field_type(t,f,e)
            e.ty=t;return t
        if e.kind=='index':
            at=self.expr(e.a[0]);
            if at.kind!='array':self.err('indexed assignment requires []T',e)
            self.req(name_ty('u64'),self.expr(e.a[1],name_ty('u64')),e.a[1]);return at.a[0]
        if e.kind=='unary' and e.a[0]=='*':
            rt=self.expr(e.a[1]);
            if rt.kind!='ref':self.err('* assignment requires ref T',e)
            return rt.a[0]
        if e.kind=='field':
            try:
                bt=self.place(e.a[0]); return self.field_type(bt,e.a[1],e)
            except LangError:
                bt=self.expr(e.a[0])
                if bt.kind=='ref':return self.field_type(bt,e.a[1],e)
                self.err('field assignment requires an assignable struct or a ref-to-struct value',e)
        self.err('expression is not assignable',e)
    def eval_const(self,n):
        c=self.consts[n]
        if c.state==2:return c.value
        if c.state==1:self.err(f'constant cycle involving {n}',c.expr)
        c.state=1; old=self.scopes;self.scopes=[]
        val,ty=self.const_expr(c.expr,c.ty)
        self.req(c.ty,ty,c.expr);c.value=val;c.state=2;self.scopes=old;return val
    def const_expr(self,e,expected=None):
        k=e.kind
        if k=='bool':return e.a[0],name_ty('bool')
        if k=='byte':return e.a[0],name_ty('u8')
        if k=='int':
            t=expected if expected is not None and int_info(expected) else name_ty('i64');v=parse_int_text(e.a[0]);
            if int_info(t):
                w,sg=int_info(t);lo=-(1<<(w-1)) if sg else 0;hi=(1<<(w-1))-1 if sg else (1<<w)-1
                if not(lo<=v<=hi):self.err(f'integer literal {v} does not fit {t}',e)
            return v,t
        if k=='float':
            t=expected if expected is not None and expected.kind=='name' and expected.a[0][0] in FLOATS else name_ty('f64');v=float(e.a[0].replace('_',''));return fround(v,t),t
        if k=='unit':return (),UNIT
        if k=='qname' and len(e.a[0])==1 and e.a[0][0] in self.consts:
            n=e.a[0][0];return self.eval_const(n),self.consts[n].ty
        if k=='unary' and e.a[0] in ('-','~','!'):
            v,t=self.const_expr(e.a[1],expected); opx=e.a[0]
            if opx=='-':return -v,t
            if opx=='~':return ~v,t
            return (not v),t
        if k=='binary':
            lv,lt=self.const_expr(e.a[1],expected); rhs_exp=name_ty('u64') if e.a[0] in ('<<','>>') else lt; rv,rt=self.const_expr(e.a[2],rhs_exp);out=self.binop(e.a[0],lt,rt,e)
            return self.eval_scalar_op(e.a[0],lv,rv,lt),out
        if k=='cast':
            v,t=self.const_expr(e.a[0]);to=self.resolve_ty(e.a[1]);self.check_cast(t,to,e);return self.cast_value(v,t,to),to
        self.err('constant expression may only use scalar literals, constants, scalar operators, and casts',e)
    def eval_scalar_op(self,opx,a,b,t):
        return scalar_value(opx,a,b,t,LangError)
    def cast_value(self,v,fr,to,fault=LangError):
        if int_info(to):
            if isinstance(v,float):
                if not math.isfinite(v):raise fault('float-to-int cast out of range')
                v=math.trunc(v)
                w,s=int_info(to);lo=-(1<<(w-1)) if s else 0;hi=(1<<(w-1))-1 if s else (1<<w)-1
                if not(lo<=v<=hi):raise fault('float-to-int cast out of range')
                return v
            return wrap_int(int(v),to)
        return fround(float(v),to)
    def external_member_type(self,alias,rest,node):
        q=self.imports[alias]
        mod=self.import_modules.get(q)
        if mod is None:
            hm=self.host_modules.get(q)
            if hm is None:self.err(f'unresolved module {".".join(q)}',node)
            return hm.member_type(rest,node)
        return mod.member_type(rest,node,external=True)

@dataclass
class CheckedModule:
    checker:Checker
    def member_type(self,rest,node=None,external=False):
        if len(rest)!=1:raise LangError('only direct module members are currently addressable',node.span if isinstance(node,N) else None)
        n=rest[0]; c=self.checker
        if n in c.consts:
            if external and not c.consts[n].public:raise LangError(f'{n} is private')
            return c.consts[n].ty
        if n in c.funcs:
            f=c.funcs[n]
            if external and not f.public:raise LangError(f'{n} is private')
            if f.gps:raise LangError('generic imported function values are not first-class')
            return fnty([t for _,t in f.params],f.ret)
        raise LangError(f'unknown module member {n}')

# ---------- runtime / interpreter ----------

class UnitVal:
    def __repr__(self):return '()'
UNITV=UnitVal()
@dataclass
class SomeVal: value:Any
@dataclass
class EnumVal: name:str; variant:str; payload:list[Any]
@dataclass
class StructVal: name:str; fields:dict[str,Any]
class ArrayObj:
    def __init__(self,items=()):self.items=list(items)
    def __repr__(self):return f'Array({self.items!r})'
class RefObj:
    def __init__(self,value):self.value=value
    def __repr__(self):return f'Ref({self.value!r})'
@dataclass(frozen=True)
class UserFnVal: name:str
@dataclass(frozen=True)
class AnonFnVal: node_id:int
@dataclass
class HostFnVal: fn:Callable

class ReturnSig(Exception):
    def __init__(self,v):self.v=v
class BreakSig(Exception):pass
class ContinueSig(Exception):pass
class TrapSig(Exception):pass

class Place:
    def __init__(self,get,set):self.get=get;self.set=set

class Interpreter:
    def __init__(self,checked:CheckedModule,host_modules:dict|None=None):
        self.cm=checked;self.c=checked.checker;self.host_modules=host_modules or {};self.frames=[];self.anon={}
        self.live_refs=weakref.WeakSet();self.live_arrays=weakref.WeakSet()
        self.top_consts={n:ci.value for n,ci in self.c.consts.items()}
    def alloc_ref(self,v):
        r=RefObj(copy_value(v));self.live_refs.add(r);return r
    def alloc_array(self,items=()):
        a=ArrayObj([copy_value(x) for x in items]);self.live_arrays.add(a);return a
    def pushframe(self,initial=None):self.frames.append(dict(initial or {}))
    def popframe(self):self.frames.pop()
    def get_local(self,n):
        for f in reversed(self.frames):
            if n in f:return f[n]
        raise TrapSig(f'unknown local {n}')
    def set_local(self,n,v):
        for f in reversed(self.frames):
            if n in f:f[n]=copy_value(v);return
        raise TrapSig(f'unknown local {n}')
    def run(self,name='main',args=()):return self.call_user(self.c.funcs[name],list(args))
    def call_user(self,f:FnInfo,args):
        self.pushframe({n:copy_value(v) for (n,_),v in zip(f.params,args)})
        try:
            self.block(f.body,new=False)
            return UNITV
        except ReturnSig as r:return copy_value(r.v)
        finally:self.popframe()
    def block(self,ss,new=True):
        if new:self.pushframe()
        try:
            for s in ss:self.stmt(s)
        finally:
            if new:self.popframe()
    def stmt(self,s):
        k=s.kind
        if k=='var':self.frames[-1][s.a[0]]=copy_value(self.eval(s.a[2]));return
        if k=='assign':
            l,opx,r=s.a;p=self.place(l); old=p.get()
            if opx=='=':nv=self.eval(r)
            else:nv=self.scalar_op(opx[:-1],old,self.eval(r),l.ty)
            p.set(copy_value(nv));return
        if k=='exprstmt':self.eval(s.a[0]);return
        if k=='if':
            ok,bind=self.cond(s.a[0])
            if ok:
                self.pushframe(bind)
                try:self.block(s.a[1],False)
                finally:self.popframe()
            else:self.block(s.a[2])
            return
        if k=='while':
            while True:
                ok,bind=self.cond(s.a[0])
                if not ok:break
                broke=False; self.pushframe(bind)
                try:
                    self.block(s.a[1],False)
                except ContinueSig:pass
                except BreakSig:broke=True
                finally:self.popframe()
                if broke:break
            return
        if k=='for':
            init,c,step,b=s.a;self.pushframe()
            try:
                if init:self.stmt(init)
                while True:
                    if c:
                        ok,_=self.cond(c)
                        if not ok:break
                    try:self.block(b)
                    except ContinueSig:pass
                    except BreakSig:break
                    if step:self.stmt(step)
            finally:self.popframe()
            return
        if k=='forin':
            n,e,b=s.a; a=self.eval(e); i=0
            while i<len(a.items):
                broke=False; self.pushframe({n:copy_value(a.items[i])})
                try:
                    self.block(b,False)
                except ContinueSig:pass
                except BreakSig:broke=True
                finally:self.popframe()
                if broke:break
                i+=1
            return
        if k=='match':
            v=self.eval(s.a[0])
            for p,b in s.a[1]:
                m=self.match(p,v,s.a[0].ty)
                if m is not None:
                    self.pushframe(m)
                    try:self.block(b,False)
                    finally:self.popframe()
                    return
            raise TrapSig('non-exhaustive match reached at runtime')
        if k=='return':raise ReturnSig(UNITV if s.a[0] is None else self.eval(s.a[0]))
        if k=='break':raise BreakSig()
        if k=='continue':raise ContinueSig()
        if k=='trap':raise TrapSig('trap')
        raise TrapSig(f'unhandled stmt {k}')
    def cond(self,c):
        if c.kind=='is':
            v=self.eval(c.a[0]);m=self.match(c.a[1],v,c.a[0].ty);return m is not None,(m or {})
        return bool(self.eval(c)),{}
    def match(self,p,v,t):
        k=p.kind
        if k=='p_wild':return {}
        if k=='p_bind':return {p.a[0]:copy_value(v)}
        if k=='p_unit':return {} if v is UNITV else None
        if k=='p_none':return {} if v is None else None
        if k=='p_some':return None if not isinstance(v,SomeVal) else self.match(p.a[0],v.value,t.a[0])
        if k=='p_bool':return {} if v is p.a[0] else None
        if k=='p_int':return {} if v==parse_int_text(p.a[0]) else None
        if k=='p_byte':return {} if v==p.a[0] else None
        if k=='p_name':
            q,subs=p.a
            variant=self.c._variant_for_pattern(q,t)
            if variant is None and len(q)==1 and not subs:return {q[0]:copy_value(v)}
            if variant is None:return None
            en,vn,pts=variant
            if not isinstance(v,EnumVal) or v.name!=en or v.variant!=vn:return None
            out={}
            for sp,pv,pt in zip(subs,v.payload,pts):
                m=self.match(sp,pv,pt)
                if m is None:return None
                out.update(m)
            return out
        return None
    def eval(self,e):
        k=e.kind
        if k=='unit':return UNITV
        if k in ('bool','byte'):return e.a[0]
        if k=='int':return wrap_int(parse_int_text(e.a[0]),e.ty)
        if k=='float':return fround(float(e.a[0].replace('_','')),e.ty)
        if k=='string':return self.alloc_array(e.a[0])
        if k=='none':return None
        if k=='some':return SomeVal(copy_value(self.eval(e.a[0])))
        if k=='qname':return self.qvalue(e.a[0],e)
        if k=='array':return self.alloc_array(self.eval(x) for x in e.a[0])
        if k=='repeat':
            v=self.eval(e.a[0]);n=self.eval(e.a[1]);return self.alloc_array(copy_value(v) for _ in range(n))
        if k=='unary':
            opx,x=e.a
            if opx=='*':return copy_value(self.eval(x).value)
            v=self.eval(x)
            if opx=='!':return not v
            if opx=='~':return wrap_int(~v,e.ty)
            if opx=='-':return wrap_int(-v,e.ty) if int_info(e.ty) else fround(-v,e.ty)
        if k=='is':
            v=self.eval(e.a[0]); return self.match(e.a[1],v,e.a[0].ty) is not None
        if k=='binary':
            opx,l,r=e.a
            if opx=='&&':
                a=self.eval(l);return bool(a and self.eval(r))
            if opx=='||':
                a=self.eval(l);return bool(a or self.eval(r))
            return self.scalar_op(opx,self.eval(l),self.eval(r),l.ty)
        if k=='cast':return self.c.cast_value(self.eval(e.a[0]),e.a[0].ty,e.ty,TrapSig)
        if k=='new':return self.alloc_ref(self.eval(e.a[0]))
        if k=='index':
            a=self.eval(e.a[0]);i=self.eval(e.a[1])
            if i<0 or i>=len(a.items):raise TrapSig('array index out of bounds')
            return copy_value(a.items[i])
        if k=='field':return copy_value(self.place(e).get())
        if k=='structlit':
            cal,fs=e.a; n=cal.a[0][0];return StructVal(n,{fn:copy_value(self.eval(x)) for fn,x in fs})
        if k=='call':
            cal,args=e.a
            if cal.kind=='qname' and len(cal.a[0])==1:
                n=cal.a[0][0]
                if n=='len':return len(self.eval(args[0]).items)
                if n=='push':self.eval(args[0]).items.append(copy_value(self.eval(args[1])));return UNITV
                if n=='pop':
                    a=self.eval(args[0])
                    if not a.items:raise TrapSig('pop from empty array')
                    return copy_value(a.items.pop())
                if n=='splice':
                    a=self.eval(args[0]); start=self.eval(args[1]); end=self.eval(args[2]); repl=self.eval(args[3])
                    if start<0 or end<start or end>len(a.items):raise TrapSig('splice range out of bounds')
                    snap=[copy_value(x) for x in repl.items]
                    a.items[start:end]=snap
                    return UNITV
                if n in self.c.funcs:return self.call_user(self.c.funcs[n],[self.eval(a) for a in args])
            if hasattr(e,'resolved_variant'):
                et,vn=e.resolved_variant
                return EnumVal(et.a[0][0],vn,[copy_value(self.eval(a)) for a in args])
            fv=self.eval(cal); av=[self.eval(a) for a in args];return self.call_value(fv,av)
        if k=='anonfn':
            self.anon[id(e)]=e;return AnonFnVal(id(e))
        raise TrapSig(f'unhandled expr {k}')
    def qvalue(self,q,e):
        try:
            v=self.get_local(q[0]); start=1
            for f in q[start:]:v=self.get_field(v,f)
            return copy_value(v)
        except TrapSig:pass
        if len(q)==1 and q[0] in self.top_consts:return self.top_consts[q[0]]
        if len(q)==1 and q[0] in self.c.funcs:return UserFnVal(q[0])
        if hasattr(e,'resolved_variant'):
            et,vn=e.resolved_variant
            return EnumVal(et.a[0][0],vn,[])
        if q[0] in self.c.imports:
            modq=self.c.imports[q[0]]; hm=self.host_modules.get(modq)
            if hm:return hm.get_value(q[1:])
        raise TrapSig('unknown value '+'.'.join(q))
    def call_value(self,f,args):
        if isinstance(f,UserFnVal):return self.call_user(self.c.funcs[f.name],args)
        if isinstance(f,AnonFnVal):
            e=self.anon[f.node_id];ps,rt,b=e.a; self.pushframe({n:copy_value(v) for (n,_),v in zip(ps,args)})
            try:
                self.block(b,False);return UNITV
            except ReturnSig as r:return copy_value(r.v)
            finally:self.popframe()
        if isinstance(f,HostFnVal):return f.fn(*args)
        raise TrapSig('value is not callable')
    def get_field(self,v,f):
        if isinstance(v,RefObj):v=v.value
        if not isinstance(v,StructVal):raise TrapSig('field on non-struct')
        return v.fields[f]
    def place(self,e):
        if e.kind=='qname':
            q=e.a[0]
            # find owning frame once; then traverse fields without reevaluating
            owner=None
            for fr in reversed(self.frames):
                if q[0] in fr:owner=fr;break
            if owner is None:raise TrapSig('place does not start with local')
            if len(q)==1:return Place(lambda:owner[q[0]],lambda v:owner.__setitem__(q[0],v))
            cur=owner[q[0]]
            for f in q[1:-1]:
                if isinstance(cur,RefObj):cur=cur.value
                cur=cur.fields[f]
            last=q[-1]
            if isinstance(cur,RefObj):cur=cur.value
            return Place(lambda:cur.fields[last],lambda v:cur.fields.__setitem__(last,v))
        if e.kind=='index':
            a=self.eval(e.a[0]);i=self.eval(e.a[1])
            if i<0 or i>=len(a.items):raise TrapSig('array index out of bounds')
            return Place(lambda:a.items[i],lambda v:a.items.__setitem__(i,v))
        if e.kind=='unary' and e.a[0]=='*':
            r=self.eval(e.a[1]);return Place(lambda:r.value,lambda v:setattr(r,'value',v))
        if e.kind=='field':
            # If the base is itself an assignable value (notably an array element
            # containing a value struct), preserve that storage identity instead of
            # evaluating/copying the base.  A ref-valued expression may be evaluated
            # once because the referent itself supplies storage identity.
            try:
                bp=self.place(e.a[0]); b=bp.get()
            except TrapSig:
                b=self.eval(e.a[0])
            if isinstance(b,RefObj):b=b.value
            if not isinstance(b,StructVal):raise TrapSig('field place on non-struct')
            f=e.a[1];return Place(lambda:b.fields[f],lambda v:b.fields.__setitem__(f,v))
        raise TrapSig('not a place')
    def scalar_op(self,opx,a,b,t):
        return scalar_value(opx,a,b,t,TrapSig)



def copy_value(v):
    # Language value-copy semantics: aggregates inline-copy; arrays/refs/functions are handle values.
    if v is UNITV or v is None or isinstance(v,(bool,int,float,ArrayObj,RefObj,UserFnVal,AnonFnVal,HostFnVal)):return v
    if isinstance(v,SomeVal):return SomeVal(copy_value(v.value))
    if isinstance(v,StructVal):return StructVal(v.name,{k:copy_value(x) for k,x in v.fields.items()})
    if isinstance(v,EnumVal):return EnumVal(v.name,v.variant,[copy_value(x) for x in v.payload])
    return v

# ---------- source-module linker ----------

INTERNAL_SEP='$'
def internal_name(mod:tuple[str,...],n:str)->str:
    return INTERNAL_SEP.join(mod)+INTERNAL_SEP+n

class Program:
    """Links logical source modules without filesystem assumptions, then uses the ordinary checker/runtime."""
    def __init__(self,sources:dict[tuple[str,...],str],host_modules:dict|None=None):
        self.sources={tuple(k):v for k,v in sources.items()};self.host_modules=host_modules or {}
        self.parsed={m:Parser(s).program() for m,s in self.sources.items()}
        self.tops={};self.imports={};self.exports={}
        for m,ast in self.parsed.items():
            tops={};imps={};exports=set()
            for d in ast.a[0]:
                if d.kind=='import':
                    q,alias=d.a;imps[alias or q[-1]]=q
                elif d.kind in ('const','struct','enum','fn'):
                    public,n=d.a[0],d.a[1];tops[n]=d.kind
                    if public:exports.add(n)
            self.tops[m]=tops;self.imports[m]=imps;self.exports[m]=exports
        self.order=self._toposort()
        self.merged=self._rewrite_merge()
        self.checked=Checker(self.merged,('__linked__',),host_modules=self.host_modules).checked()
    def _toposort(self):
        state={};out=[]
        def dfs(m,path):
            if state.get(m)==1:raise LangError('import cycle: '+' -> '.join('.'.join(x) for x in path+[m]))
            if state.get(m)==2:return
            state[m]=1
            for q in self.imports[m].values():
                if q in self.sources:dfs(q,path+[m])
                elif q not in self.host_modules:raise LangError(f'unresolved module {".".join(q)}')
            state[m]=2;out.append(m)
        for m in self.sources:dfs(m,[])
        return out
    def _rewrite_merge(self):
        ds=[]
        for m in self.order:
            for alias,target in self.imports[m].items():
                if target in self.host_modules:
                    hd=N('import',(target,internal_name(m,alias)),None); hd.origin=m; ds.append(hd)
            for d in self.parsed[m].a[0]:
                if d.kind=='import':continue
                rd=self._decl(m,d);rd.origin=m;rd.reserved=set(self.tops[m])|set(self.imports[m]);ds.append(rd)
        return N('module',(tuple(ds),),None)
    def _resolve_source_name(self,m,q,node=None):
        if not q:return q
        first=q[0]
        if first in self.imports[m]:
            target=self.imports[m][first]
            if target in self.sources:
                if len(q)<2:raise LangError('source module name is not a runtime value',node.span if isinstance(node,N) else None)
                member=q[1]
                if member not in self.tops[target]:raise LangError(f'unknown member {member} of {".".join(target)}')
                if member not in self.exports[target]:raise LangError(f'{".".join(target)}.{member} is private')
                return (internal_name(target,member),)+q[2:]
            return (internal_name(m,first),)+q[1:] # unique internal host alias
        if first in self.tops[m]:return (internal_name(m,first),)+q[1:]
        return q
    def _ty(self,m,t,gps=frozenset()):
        if t.kind=='name':
            q,args=t.a
            if len(q)==1 and q[0] in gps:return t
            return Ty('name',(self._resolve_source_name(m,q),tuple(self._ty(m,x,gps) for x in args)))
        if t.kind in ('opt','ref','array'):return Ty(t.kind,(self._ty(m,t.a[0],gps),))
        if t.kind=='fn':return fnty([self._ty(m,x,gps) for x in t.a[0]],self._ty(m,t.a[1],gps))
        return t
    def _expr(self,m,e,gps=frozenset()):
        if not isinstance(e,N):return e
        k=e.kind
        if k=='qname':return N(k,(self._resolve_source_name(m,e.a[0],e),),e.span)
        if k=='cast':return N(k,(self._expr(m,e.a[0],gps),self._ty(m,e.a[1],gps)),e.span)
        if k=='is':return N(k,(self._expr(m,e.a[0],gps),self._pattern(m,e.a[1],gps)),e.span)
        if k=='anonfn':
            ps,rt,b=e.a; return N(k,(tuple((n,self._ty(m,t,gps)) for n,t in ps),self._ty(m,rt,gps),tuple(self._stmt(m,s,gps) for s in b)),e.span)
        # recursively rewrite expressions/embedded types
        aa=[]
        for x in e.a:
            if isinstance(x,N):aa.append(self._expr(m,x,gps))
            elif isinstance(x,Ty):aa.append(self._ty(m,x,gps))
            elif isinstance(x,tuple):
                ys=[]
                for y in x:
                    if isinstance(y,N):ys.append(self._expr(m,y,gps))
                    elif isinstance(y,tuple) and len(y)==2 and isinstance(y[1],N):ys.append((y[0],self._expr(m,y[1],gps)))
                    else:ys.append(y)
                aa.append(tuple(ys))
            else:aa.append(x)
        return N(k,tuple(aa),e.span)
    def _pattern(self,m,p,gps=frozenset()):
        if p.kind=='p_name':
            q,subs=p.a
            # plain binding must not be rewritten merely because its spelling matches some top-level thing; no-shadowing checker will reject such spelling anyway.
            rq=self._resolve_source_name(m,q,p) if len(q)>1 or (len(q)==1 and q[0] in self.tops[m]) else q
            return N('p_name',(rq,tuple(self._pattern(m,x,gps) for x in subs)),p.span)
        return N(p.kind,tuple(self._pattern(m,x,gps) if isinstance(x,N) else x for x in p.a),p.span)
    def _stmt(self,m,s,gps=frozenset()):
        k=s.kind
        if k=='var':return N(k,(s.a[0],self._ty(m,s.a[1],gps) if s.a[1] else None,self._expr(m,s.a[2],gps)),s.span)
        if k=='assign':return N(k,(self._expr(m,s.a[0],gps),s.a[1],self._expr(m,s.a[2],gps)),s.span)
        if k=='exprstmt':return N(k,(self._expr(m,s.a[0],gps),),s.span)
        if k in ('if','while'):
            c=s.a[0]
            if c.kind=='is':c=N('is',(self._expr(m,c.a[0],gps),self._pattern(m,c.a[1],gps)),c.span)
            else:c=self._expr(m,c,gps)
            if k=='if':return N(k,(c,tuple(self._stmt(m,x,gps) for x in s.a[1]),tuple(self._stmt(m,x,gps) for x in s.a[2])),s.span)
            return N(k,(c,tuple(self._stmt(m,x,gps) for x in s.a[1])),s.span)
        if k=='for':
            init,c,step,b=s.a
            if c:
                c=N('is',(self._expr(m,c.a[0],gps),self._pattern(m,c.a[1],gps)),c.span) if c.kind=='is' else self._expr(m,c,gps)
            return N(k,(self._stmt(m,init,gps) if init else None,c,self._stmt(m,step,gps) if step else None,tuple(self._stmt(m,x,gps) for x in b)),s.span)
        if k=='forin':return N(k,(s.a[0],self._expr(m,s.a[1],gps),tuple(self._stmt(m,x,gps) for x in s.a[2])),s.span)
        if k=='match':return N(k,(self._expr(m,s.a[0],gps),tuple((self._pattern(m,p,gps),tuple(self._stmt(m,x,gps) for x in b)) for p,b in s.a[1])),s.span)
        if k=='return':return N(k,(self._expr(m,s.a[0],gps) if s.a[0] else None,),s.span)
        return N(k,s.a,s.span)
    def _decl(self,m,d):
        k=d.kind
        if k=='const':
            pub,n,t,e=d.a;return N(k,(pub,internal_name(m,n),self._ty(m,t),self._expr(m,e)),d.span)
        if k=='struct':
            pub,n,gps,fs=d.a; reserved=set(self.tops[m])|set(self.imports[m]);
            if set(gps)&reserved: raise LangError('generic parameter shadows module name')
            gs=frozenset(gps); out=N(k,(pub,internal_name(m,n),gps,tuple((fp,fn,self._ty(m,t,gs),sp) for fp,fn,t,sp in fs)),d.span);return out
        if k=='enum':
            pub,n,gps,vs=d.a;reserved=set(self.tops[m])|set(self.imports[m]);
            if set(gps)&reserved: raise LangError('generic parameter shadows module name')
            gs=frozenset(gps);return N(k,(pub,internal_name(m,n),gps,tuple((v,tuple(self._ty(m,t,gs) for t in ts)) for v,ts in vs)),d.span)
        if k=='fn':
            pub,n,gps,ps,rt,b=d.a;reserved=set(self.tops[m])|set(self.imports[m]);
            if set(gps)&reserved: raise LangError('generic parameter shadows module name')
            gs=frozenset(gps);return N(k,(pub,internal_name(m,n),gps,tuple((pn,self._ty(m,t,gs)) for pn,t in ps),self._ty(m,rt,gs),tuple(self._stmt(m,s,gs) for s in b)),d.span)
        raise LangError('unexpected decl during link')
    def interpreter(self):return Interpreter(self.checked,self.host_modules)
    def run(self,module:tuple[str,...],name='main',args=()):return self.interpreter().run(internal_name(tuple(module),name),args)

# ---------- host-module API ----------

@dataclass(frozen=True)
class OpaqueVal:
    type_id:tuple[str,...]
    payload:Any

class HostModule:
    """Typed implementation-defined module surface. No ABI/layout is exposed to language code."""
    def __init__(self,name:tuple[str,...]):
        self.name=tuple(name);self.types=set();self.func_types={};self.func_values={};self.const_types={};self.const_values={}
    def opaque_type(self,name:str):
        self.types.add(name);return name_ty(('__host__',)+self.name+(name,))
    def function(self,name:str,params:list[Ty],ret:Ty,fn:Callable):
        self.func_types[name]=fnty(params,ret);self.func_values[name]=HostFnVal(fn);return self
    def constant(self,name:str,ty:Ty,val:Any):
        self.const_types[name]=ty;self.const_values[name]=val;return self
    def resolve_type(self,rest,args):
        if len(rest)!=1 or rest[0] not in self.types:raise LangError(f'unknown opaque type {".".join(self.name+tuple(rest))}')
        if args:raise LangError('host opaque types do not take type arguments')
        return name_ty(('__host__',)+self.name+(rest[0],))
    def member_type(self,rest,node=None):
        if len(rest)!=1:raise LangError('host module member access must be direct',node.span if isinstance(node,N) else None)
        n=rest[0]
        if n in self.func_types:return self.func_types[n]
        if n in self.const_types:return self.const_types[n]
        raise LangError(f'unknown host member {n}',node.span if isinstance(node,N) else None)
    def get_value(self,rest):
        if len(rest)!=1:raise TrapSig('bad host member')
        n=rest[0]
        if n in self.func_values:return self.func_values[n]
        if n in self.const_values:return self.const_values[n]
        raise TrapSig(f'unknown host member {n}')
