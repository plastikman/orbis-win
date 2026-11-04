from ftplib import FTP
import argparse
import struct

parser = argparse.ArgumentParser(description="Read PE headers from a GoldHEN FTP file")
parser.add_argument("path", help="remote file path")
parser.add_argument("--host", required=True, help="PS4 address")
parser.add_argument("--port", type=int, default=2121)
args = parser.parse_args()

buf = bytearray()
f = FTP(); f.connect(args.host, args.port, timeout=30); f.login()
def grab(b):
    buf.extend(b)
    if len(buf) > 65536:
        raise EOFError
try:
    f.retrbinary('RETR ' + args.path, grab, blocksize=8192)
except EOFError:
    pass
except Exception as e:
    print('ftp:', e)
try: f.quit()
except Exception: pass

d = bytes(buf)
print('read %d bytes of %s' % (len(d), args.path))
e_lfanew = struct.unpack_from('<I', d, 0x3c)[0]
assert d[e_lfanew:e_lfanew+4] == b'PE\0\0', 'no PE signature'
machine, nsec = struct.unpack_from('<HH', d, e_lfanew+4)
characteristics = struct.unpack_from('<H', d, e_lfanew+4+18)[0]
opt = e_lfanew + 24
magic = struct.unpack_from('<H', d, opt)[0]
base = struct.unpack_from('<I' if magic == 0x10b else '<Q', d, opt + 28)[0]
print('machine=%#06x  magic=%#06x (%s)  ImageBase=%#x' %
      (machine, magic, 'PE32' if magic == 0x10b else 'PE32+', base))
print('Characteristics=%#06x  RELOCS_STRIPPED=%s  DLL=%s' %
      (characteristics, bool(characteristics & 0x0001), bool(characteristics & 0x2000)))
dllchar = struct.unpack_from('<H', d, opt + (70 if magic == 0x10b else 70))[0]
print('DllCharacteristics=%#06x  DYNAMIC_BASE(ASLR)=%s' % (dllchar, bool(dllchar & 0x0040)))
# section table
sec = opt + struct.unpack_from('<H', d, e_lfanew+4+16)[0]
names = []
for i in range(nsec):
    off = sec + i*40
    if off + 40 > len(d): break
    names.append(d[off:off+8].rstrip(b'\0').decode('latin1'))
print('sections(%d): %s' % (nsec, ' '.join(names)))
print('has .reloc :', any(n.startswith('.reloc') for n in names))
rva, size = struct.unpack_from('<II', d, opt + (96 if magic == 0x10b else 112) + 5*8)
print('BASERELOC dir: rva=%#x size=%#x' % (rva, size))
