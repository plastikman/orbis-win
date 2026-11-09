#!/usr/bin/env python3
"""Bytes of .bss padding a PRX needs so create-fself maps the end of its .bss.

create-fself sizes the writable segment as align16(.data) + .bss, leaving out
.got.plt, which sits between them, so the converted segment ends short of the
real end of .bss. The tail is mapped only if the 16 KiB page rounding covers
it; when it does not, rtld refuses the module (reloc_non_plt ... ref=<module>).
See scripts/prx-ps4.sh, where this was first found (wineserver, 01.13), and
build-relocatable-wine-ps4.sh (the app module, 01.55).

    bss-tail-pad.py <module.shared.elf> <module.oelf>

Prints 0 when the end is mapped, else the pad that moves the converted end to
0x100 into the next page.
"""
import struct
import sys


def writable_loads(path):
    data = open(path, 'rb').read()
    phoff, = struct.unpack_from('<Q', data, 0x20)
    phentsize, phnum = struct.unpack_from('<HH', data, 0x36)
    out = []
    for i in range(phnum):
        kind, flags, _off, va, _pa, _fs, ms, _al = struct.unpack_from('<IIQQQQQQ', data, phoff + i * phentsize)
        if kind == 1 and flags & 2:
            out.append((va, ms))
    return out


def main():
    elf, oelf = writable_loads(sys.argv[1]), writable_loads(sys.argv[2])
    va, ms = max(elf, key=lambda s: s[0] + s[1])
    end = max((ov + om for ov, om in oelf if ov == va), default=0)
    if ((end + 0x3fff) & ~0x3fff) >= va + ms:
        print(0)
    else:
        print((0x4100 - (end & 0x3fff)) & 0x3fff or 0x100)


if __name__ == '__main__':
    main()
