import sys
D="/mnt/metalcoat/Simpsons Bowling/Simpsons Bowling/duckstation-sb-2/emulationfiles/simpbowl/nvram"
def rd(n):
    with open(f"{D}/{n}","rb") as f: return f.read()
f0,f1,f2,f3 = rd("flash0"),rd("flash1"),rd("flash2"),rd("flash3")
assert len(f0)==len(f1)==len(f2)==len(f3)==0x200000, "size mismatch"
# konami.cpp: FA<0x200000 -> word=f0[FA]|f1[FA]<<8 ; FA>=0x200000 -> a=FA&0x1FFFFF, word=f2[a]|f3[a]<<8
# pre-interleave: byte 2*FA = lo, 2*FA+1 = hi  => 8MB image, linear word index FA in 0..0x3FFFFF
out=bytearray(0x800000)
for FA in range(0x200000):
    out[2*FA]   = f0[FA]; out[2*FA+1]   = f1[FA]
for FA in range(0x200000):
    o=2*(0x200000+FA); out[o]=f2[FA]; out[o+1]=f3[FA]
with open("build/flash_573_simpbowl.bin","wb") as f: f.write(out)
# verify: first word should be f0[0]|f1[0]<<8
print(f"image size: {len(out)} (0x{len(out):X}) = {len(out)//1024//1024}MB")
print(f"word0  lo=0x{out[0]:02X} hi=0x{out[1]:02X}  (f0[0]=0x{f0[0]:02X} f1[0]=0x{f1[0]:02X})")
print(f"word @0x200000: lo=0x{out[0x400000]:02X} hi=0x{out[0x400001]:02X}  (f2[0]=0x{f2[0]:02X} f3[0]=0x{f3[0]:02X})")
