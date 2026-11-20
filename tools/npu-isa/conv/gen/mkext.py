import struct,sys
d=open(sys.argv[1],"rb").read()
shoff=struct.unpack_from("<I",d,0x20)[0]; shentsize,shnum,shstrndx=struct.unpack_from("<HHH",d,0x2e)
secs=[struct.unpack_from("<IIIIIIIIII",d,shoff+i*shentsize) for i in range(shnum)]
st=secs[shstrndx]
nm=lambda o: d[st[4]+o:d.index(b"\0",st[4]+o)].decode()
for s in secs:
    if nm(s[0])==".text": open(sys.argv[2],"wb").write(d[s[4]:s[4]+s[5]]); print("text", s[5])
