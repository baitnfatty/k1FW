import struct, re
data = open("CR4CU220812S12_ota_X2000E_V1.1.0.27.20251225.img","rb").read(0x200000)
# Global header first ints
print("=== global header @0x120 ===")
for off in range(0x120,0x140,4):
    print(f" 0x{off:03x}: u32=0x{struct.unpack_from('<I',data,off)[0]:08x} ({struct.unpack_from('<I',data,off)[0]})")
# Records: anchor on 'mmcblk0pN'. filename = ascii ending just before, at dev-0x80.
devs=[(m.start(), m.group().decode()) for m in re.finditer(rb'mmcblk0p\d', data)]
print("\n=== per-record ===")
for doff,dev in devs:
    fn_off = doff-0x80
    fn = data[fn_off:doff].split(b'\x00')[0].decode('latin1','replace')
    # trailer ints: scan 0x40 bytes after device for non-zero u32 pairs
    tail = data[doff+0x0: doff+0x60]
    ints=[struct.unpack_from('<I',data,doff+i)[0] for i in range(0x40,0x60,4)]
    print(f"{dev}  file={fn}")
    print(f"    trailer u32@+0x40..: " + " ".join(f"0x{v:08x}" for v in ints))
