import struct, sys
f = open("CR4CU220812S12_ota_X2000E_V1.1.0.27.20251225.img","rb")
data = f.read(0x200000)  # header well within first 2MB
# Global header: name@0x00, desc@0x80, ts@0xC0. Count/table starts ~0x120.
# Table entry: locate each filename + device + ints. Scan for 'mmcblk0p' anchors.
import re
# find all CR4CU...(.bin|.squashfs|.img) filenames with positions
names=[(m.start(), m.group().decode('latin1')) for m in re.finditer(rb'CR4CU220812S12_[A-Za-z0-9._-]+\.(bin|squashfs|img)', data)]
devs=[(m.start(), m.group().decode()) for m in re.finditer(rb'mmcblk0p\d', data)]
print("=== filenames found (offset, name) ===")
for o,n in names: print(f"0x{o:06x}  {n}")
print("\n=== device targets (offset, dev) ===")
for o,d in devs: print(f"0x{o:06x}  {d}")

# Dump 32-bit LE ints in the header table region to spot offset/size fields
print("\n=== header table region 0x120..0x120+0x100*8 as (off, u32le, u32le pairs) ===")
base=0x120
# Try to guess record size from filename spacing
if len(names)>=2:
    stride = names[1][0]-names[0][0]
    print(f"filename stride ~ 0x{stride:x} ({stride})")
