#!/usr/bin/env python3
from __future__ import annotations
import json, os, select, subprocess, sys, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def frame(obj):
    b=json.dumps(obj,separators=(',',':'),ensure_ascii=False).encode('utf-8')
    return f'Content-Length: {len(b)}\r\n\r\n'.encode()+b

class Client:
    def __init__(self,exe):
        self.p=subprocess.Popen([str(exe)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    def send(self,obj): self.p.stdin.write(frame(obj)); self.p.stdin.flush()
    def recv(self,timeout=5):
        end=time.monotonic()+timeout; hdr=b''
        while b'\r\n\r\n' not in hdr:
            rem=end-time.monotonic()
            if rem<=0: raise TimeoutError('LSP header')
            r,_,_=select.select([self.p.stdout],[],[],rem)
            if not r: raise TimeoutError('LSP header')
            hdr+=os.read(self.p.stdout.fileno(),1)
        head,body=hdr.split(b'\r\n\r\n',1)
        n=int(next(x.split(b':',1)[1] for x in head.split(b'\r\n') if x.lower().startswith(b'content-length:')))
        while len(body)<n:
            rem=end-time.monotonic()
            if rem<=0: raise TimeoutError('LSP body')
            r,_,_=select.select([self.p.stdout],[],[],rem)
            if not r: raise TimeoutError('LSP body')
            body+=os.read(self.p.stdout.fileno(),n-len(body))
        return json.loads(body[:n])
    def close(self):
        self.send({'jsonrpc':'2.0','id':99,'method':'shutdown','params':None}); self.recv()
        self.send({'jsonrpc':'2.0','method':'exit','params':None}); self.p.wait(timeout=2)

def main():
    c=Client(ROOT/'json-lsp')
    c.send({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'capabilities':{}}})
    r=c.recv(); assert r['result']['capabilities']['textDocumentSync']==2
    c.send({'jsonrpc':'2.0','method':'initialized','params':{}})
    uri='file:///tmp/l-v6-incremental.json'
    c.send({'jsonrpc':'2.0','method':'textDocument/didOpen','params':{'textDocument':{'uri':uri,'languageId':'json','version':1,'text':'{"x":"😀"}'}}})
    assert c.recv()['method']=='textDocument/publishDiagnostics'
    # Positions are UTF-16. These edits are sequential: the second range is
    # interpreted against the document after the first edit.
    c.send({'jsonrpc':'2.0','method':'textDocument/didChange','params':{'textDocument':{'uri':uri,'version':2},'contentChanges':[
        {'range':{'start':{'line':0,'character':8},'end':{'line':0,'character':8}},'text':'A'},
        {'range':{'start':{'line':0,'character':9},'end':{'line':0,'character':9}},'text':'B'},
    ]}})
    assert c.recv()['method']=='textDocument/publishDiagnostics'
    c.send({'jsonrpc':'2.0','id':2,'method':'textDocument/formatting','params':{'textDocument':{'uri':uri},'options':{'tabSize':4,'insertSpaces':True}}})
    r=c.recv(); assert '😀AB' in r['result'][0]['newText']
    c.close(); print('incremental UTF-16 LSP PASS')
if __name__=='__main__': main()
