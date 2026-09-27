#!/usr/bin/env python3
"""
Creality X2600 (K1C / K1 Max 2025) OTA package tool.

Format fully reverse-engineered and verified against the device's own validator
(`upgbox -C`) running under qemu-mipsel.

HEADER (little-endian)
  0x000  char[128]  package filename
  0x080  char[64]   description  ("Creality x2600 software")
  0x0C0  char[64]   serial/build stamp ("20251225153931")
  0x100  char[32]   version string ("V1.1.0.27.20251225")
  0x120  u32        build epoch
  0x128  u64        total package size (== file size)
  0x130  u32        image/node count
  0x134  u32        write mode
  0x138  u32        HEADER CRC32   = crc32(bytes[0x000:0x138])

NODE RECORDS: start 0x13C, stride 0xE0 (224 bytes), one per image
  +0x00  char[128]  image filename
  +0x80  char[64]   target partition ("mmcblk0p7")
  +0xC0  u64        payload size
  +0xC8  u64        payload offset (absolute, in package)
  +0xD0  u64        write offset (into partition)
  +0xD8  u32        IMAGE CRC32 = crc32(payload bytes)
  +0xDC  u32        NODE CRC32  = crc32(record[0x00:0xDC])   (covers IMAGE CRC32)

CRC = standard zlib.crc32. Node records are NOT covered by the header CRC.

DEVICE-SIDE VALIDATION (complete):
  /bin/upgchck.sh:  rejects images matching /rootfs-app.*ext4$/, then runs
                    `upgbox -C -f <file> -A`.  That is the entire gate.
  upgbox links ONLY libc — no crypto, no signature, no pubkey.
  seed.sh upg_do:   no version check, no anti-rollback. Writes the INACTIVE
                    A/B bank, then flips the flag in mmcblk0p1.

Usage:
  ota_tool.py info    <pkg>
  ota_tool.py extract <pkg> <outdir>
  ota_tool.py replace <pkg> <partition> <newpayload> <outpkg>
  ota_tool.py fixcrc  <pkg>          (in place)
"""
import sys, os, zlib, struct, shutil

BASE, STRIDE = 0x13C, 0xE0
O_SIZE, O_OFF, O_WOFS, O_IMGCRC, O_NODECRC = 0xC0, 0xC8, 0xD0, 0xD8, 0xDC


def _cstr(b):
    return b.split(b"\0")[0].decode("latin1")


def parse(d):
    n = struct.unpack_from("<I", d, 0x130)[0]
    nodes = []
    for i in range(n):
        r = BASE + i * STRIDE
        size, off, wofs = struct.unpack_from("<QQQ", d, r + O_SIZE)
        nodes.append(dict(
            i=i, rec=r,
            name=_cstr(d[r:r + 128]),
            part=_cstr(d[r + 0x80:r + 0xC0]),
            size=size, off=off, wofs=wofs,
            imgcrc=struct.unpack_from("<I", d, r + O_IMGCRC)[0],
            nodecrc=struct.unpack_from("<I", d, r + O_NODECRC)[0],
        ))
    return dict(
        name=_cstr(d[0:128]), desc=_cstr(d[0x80:0xC0]),
        stamp=_cstr(d[0xC0:0x100]), version=_cstr(d[0x100:0x120]),
        total=struct.unpack_from("<Q", d, 0x128)[0],
        count=n, mode=struct.unpack_from("<I", d, 0x134)[0],
        hdrcrc=struct.unpack_from("<I", d, 0x138)[0], nodes=nodes,
    )


def fixcrc(d):
    """Recompute every CRC. Order matters: image -> node -> header."""
    d = bytearray(d)
    for nd in parse(d)["nodes"]:
        r = nd["rec"]
        img = zlib.crc32(bytes(d[nd["off"]:nd["off"] + nd["size"]])) & 0xFFFFFFFF
        struct.pack_into("<I", d, r + O_IMGCRC, img)
        node = zlib.crc32(bytes(d[r:r + O_NODECRC])) & 0xFFFFFFFF
        struct.pack_into("<I", d, r + O_NODECRC, node)
    struct.pack_into("<Q", d, 0x128, len(d))
    struct.pack_into("<I", d, 0x138, zlib.crc32(bytes(d[0:0x138])) & 0xFFFFFFFF)
    return bytes(d)


def verify(d):
    info, bad = parse(d), []
    if zlib.crc32(d[0:0x138]) & 0xFFFFFFFF != info["hdrcrc"]:
        bad.append("header")
    for nd in info["nodes"]:
        if zlib.crc32(d[nd["off"]:nd["off"] + nd["size"]]) & 0xFFFFFFFF != nd["imgcrc"]:
            bad.append(f"{nd['part']}:image")
        if zlib.crc32(d[nd["rec"]:nd["rec"] + O_NODECRC]) & 0xFFFFFFFF != nd["nodecrc"]:
            bad.append(f"{nd['part']}:node")
    return bad


def cmd_info(pkg):
    d = open(pkg, "rb").read()
    i = parse(d)
    print(f"name    : {i['name']}\ndesc    : {i['desc']}\nversion : {i['version']}")
    print(f"stamp   : {i['stamp']}\nsize    : {i['total']} (file {len(d)})")
    print(f"nodes   : {i['count']}   mode: {i['mode']}   hdrcrc: {i['hdrcrc']:08X}\n")
    for n in i["nodes"]:
        print(f"  [{n['i']}] {n['part']:<12} size={n['size']:>10}  off=0x{n['off']:08x} "
              f"wofs={n['wofs']}  img={n['imgcrc']:08X} node={n['nodecrc']:08X}")
        print(f"       {n['name']}")
    bad = verify(d)
    print("\nCRC:", "ALL VALID" if not bad else f"INVALID -> {bad}")


def cmd_extract(pkg, outdir):
    d = open(pkg, "rb").read()
    os.makedirs(outdir, exist_ok=True)
    for n in parse(d)["nodes"]:
        p = os.path.join(outdir, f"{n['part']}_{n['name']}")
        with open(p, "wb") as f:
            f.write(d[n["off"]:n["off"] + n["size"]])
        print(f"  -> {p} ({n['size']} bytes)")


def cmd_replace(pkg, part, newfile, outpkg):
    """Replace one partition's payload. Only safe when the new payload is the
    SAME SIZE (offsets of following nodes are absolute)."""
    d = bytearray(open(pkg, "rb").read())
    new = open(newfile, "rb").read()
    tgt = [n for n in parse(d)["nodes"] if n["part"] == part]
    if not tgt:
        sys.exit(f"partition {part} not in package")
    for n in tgt:
        if len(new) != n["size"]:
            sys.exit(f"size mismatch: payload {len(new)} != node {n['size']}. "
                     "Rebuild squashfs to the exact size, or pad it.")
        d[n["off"]:n["off"] + n["size"]] = new
        print(f"  replaced {part} payload at 0x{n['off']:x}")
    out = fixcrc(bytes(d))
    open(outpkg, "wb").write(out)
    print(f"wrote {outpkg}; CRC check: {verify(out) or 'ALL VALID'}")


if __name__ == "__main__":
    a = sys.argv[1:]
    if not a:
        sys.exit(__doc__)
    c = a[0]
    if c == "info":       cmd_info(a[1])
    elif c == "extract":  cmd_extract(a[1], a[2])
    elif c == "replace":  cmd_replace(a[1], a[2], a[3], a[4])
    elif c == "fixcrc":
        out = fixcrc(open(a[1], "rb").read()); open(a[1], "wb").write(out)
        print("fixed:", verify(out) or "ALL VALID")
    else: sys.exit(__doc__)
