#!/usr/bin/env python3
import json,sys,time

def readmsg():
    headers={}
    while True:
        line=sys.stdin.buffer.readline()
        if not line:return None
        if line in (b'\r\n',b'\n'):break
        k,v=line.decode().split(':',1);headers[k.lower().strip()]=v.strip()
    n=int(headers.get('content-length','0'));return json.loads(sys.stdin.buffer.read(n))
def send(x):
    b=json.dumps(x,separators=(',',':')).encode();sys.stdout.buffer.write(f'Content-Length: {len(b)}\r\n\r\n'.encode()+b);sys.stdout.buffer.flush()
sem=0
while True:
    m=readmsg()
    if m is None:break
    method=m.get('method');mid=m.get('id')
    if method=='initialize':send({'jsonrpc':'2.0','id':mid,'result':{'capabilities':{'positionEncoding':'utf-16','textDocumentSync':2,'semanticTokensProvider':{'legend':{'tokenTypes':['namespace','type','class','enum','interface','struct','typeParameter','parameter','variable','property','enumMember','event','function','method','macro','keyword','modifier','comment','string','number','regexp','operator','decorator'],'tokenModifiers':[]},'range':True,'full':True}}}})
    elif method=='textDocument/semanticTokens/range':
        sem+=1
        if sem>1:time.sleep(.6)
        send({'jsonrpc':'2.0','id':mid,'result':{'data':[0,0,3,1,0]}})
    elif method=='shutdown':send({'jsonrpc':'2.0','id':mid,'result':None})
    elif method=='exit':break
    elif mid is not None:send({'jsonrpc':'2.0','id':mid,'result':None})
