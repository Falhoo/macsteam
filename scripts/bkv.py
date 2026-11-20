import struct

SEC, STR, INT, FLT, U64, END, I64 = 0,1,2,3,7,8,10

class N:
    __slots__=("t","name","v","kids")
    def __init__(s,t,name,v=None): s.t,s.name,s.v,s.kids=t,name,v,[]

def parse(data):
    pos=0
    def rd_name():
        nonlocal pos
        j=pos
        while j<len(data) and data[j]!=0: j+=1
        if j>=len(data): raise ValueError("unterminated name")
        n=data[pos:j]; pos=j+1
        return n
    def rd_node():
        nonlocal pos
        if pos>=len(data): return None
        t=data[pos]; pos+=1
        if t==END: return None
        name=rd_name()
        n=N(t,name)
        if t==SEC:
            while True:
                if pos>=len(data): raise ValueError("eof in section")
                if data[pos]==END: pos+=1; break
                k=rd_node()
                if k is None: break
                n.kids.append(k)
        elif t==STR: n.v=rd_name()
        elif t in (INT,FLT):
            n.v=struct.unpack("<i",data[pos:pos+4])[0]; pos+=4
        elif t in (U64,I64):
            n.v=struct.unpack("<q",data[pos:pos+8])[0]; pos+=8
        else: raise ValueError("bad type %d at %d"%(t,pos-1))
        return n
    root_type=data[0]
    assert root_type==SEC, "root must be section"
    pos=1
    root=N(SEC, rd_name())
    while True:
        if pos>=len(data): break
        if data[pos]==END:
            pos+=1; break
        k=rd_node()
        if k is None: break
        root.kids.append(k)
    return root, pos

def enc(n):
    o=bytearray()
    def w(x):
        o.append(x.t); o.extend(x.name); o.append(0)
        if x.t==SEC:
            for k in x.kids: w(k)
            o.append(END)
        elif x.t==STR: o.extend(x.v); o.append(0)
        elif x.t in (INT,FLT): o.extend(struct.pack("<i",x.v))
        elif x.t in (U64,I64): o.extend(struct.pack("<q",x.v))
    w(n)
    o.append(END)          # sentinel after root
    return bytes(o)

if __name__=="__main__":
    d=open("/tmp/dbd_schema_real.bin","rb").read()
    root,used=parse(d)
    out=enc(root)
    print("real size:",len(d),"consumed:",used,"re-encoded:",len(out))
    print("byte-identical:", out==d)
    if out!=d:
        for i,(a,b) in enumerate(zip(out,d)):
            if a!=b:
                print("first diff at",i,"mine",hex(a),"real",hex(b)); break
        print("tail mine:",out[-12:].hex(' '))
        print("tail real:",d[-12:].hex(' '))
