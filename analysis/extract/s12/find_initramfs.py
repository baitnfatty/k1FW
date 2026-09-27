import subprocess, os, lzma, gzip, io
data = open("vmlinux.bin","rb").read()
def try_decompress(off):
    # try xz, gzip, lzo (lzo needs external)
    blob = data[off:]
    # xz
    if blob[:6]==b'\xfd7zXZ\x00':
        try: return lzma.decompress(blob)  # may error on trailing; ok
        except lzma.LZMAError:
            # decompress up to first stream
            d=lzma.LZMADecompressor(); 
            try: return d.decompress(blob)
            except: return None
    if blob[:2]==b'\x1f\x8b':
        try:
            return gzip.GzipDecompressor().decompress(blob) if hasattr(gzip,'GzipDecompressor') else gzip.decompress(blob)
        except Exception:
            try:
                import zlib
                return zlib.decompress(blob, 16+zlib.MAX_WBITS)
            except: return None
    return None

# offsets from binwalk
offs = [0x7731D8, 0x94795C, 0xAA3998]
for off in offs:
    out = try_decompress(off)
    if out is None:
        print(f"0x{off:x}: decompress failed"); continue
    tag = out[:6]
    is_cpio = out[:6]==b'070701' or b'070701' in out[:8]
    fn = f"blob_{off:x}.bin"
    open(fn,"wb").write(out)
    print(f"0x{off:x}: -> {len(out)} bytes, cpio={out[:6]==b'070701'}  saved {fn}")
