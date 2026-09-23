#!/usr/bin/env python3
"""Patch an ELF64 shared object's DT_NEEDED entries in place.

Why this exists
---------------
OHOS's loader does NOT give a natively-dlopen()ed object the process-global
symbol scope. `dlsym(RTLD_DEFAULT)` finds e.g. `napi_fatal_error`, but the
addon's relocation only searches its own DT_NEEDED closure, so a `require()`d
`pty.node` dies with:

    Error relocating .../libpty.node: napi_fatal_error: symbol not found

Preloading a shim with RTLD_GLOBAL does not help. The fix is to make the host
process an explicit dependency of the addon: rewrite an existing DT_NEEDED
string in place so the addon's closure includes `libnode.so`.

Two traps
---------
1. Use the literal FILENAME `libnode.so`, never the SONAME `libnode.so.137`.
   This loader treats a DT_NEEDED as a filename and fails with
   `Error loading shared library libnode.so.137: (needed by ...)`.
2. The replacement must be no longer than the string it replaces, because we
   patch .dynstr in place (NUL padded). `libc++_shared.so` (15 chars) ->
   `libnode.so` (10) is fine; pty.node is linked against libc++_shared.so but
   libnode.so re-exports the libc++ symbols, so dropping it is safe.

Usage
-----
    elf-patch-dynamic.py --print path/to/pty.node
    elf-patch-dynamic.py --needed libc++_shared.so=libnode.so path/to/pty.node
    elf-patch-dynamic.py --needed old=new --needed old2=new2 path/to/pty.node
    elf-patch-dynamic.py --restore path/to/pty.node   # from <path>.orig

Exit codes: 0 ok, 1 error, 2 nothing to do (already patched).
"""

import argparse
import os
import shutil
import struct
import sys

DT_NULL = 0
DT_NEEDED = 1
DT_SONAME = 14

TAG_NAMES = {DT_NEEDED: 'NEEDED', DT_SONAME: 'SONAME'}


class Elf:
    def __init__(self, path):
        self.path = path
        with open(path, 'rb') as fh:
            self.data = bytearray(fh.read())
        d = self.data
        if d[:4] != b'\x7fELF':
            raise ValueError(f'{path}: not an ELF file')
        if d[4] != 2 or d[5] != 1:
            raise ValueError(f'{path}: only ELF64 little-endian is supported')
        e_shoff = struct.unpack_from('<Q', d, 0x28)[0]
        e_shentsize = struct.unpack_from('<H', d, 0x3A)[0]
        e_shnum = struct.unpack_from('<H', d, 0x3C)[0]
        e_shstrndx = struct.unpack_from('<H', d, 0x3E)[0]
        self.sections = [
            struct.unpack_from('<IIQQQQIIQQ', d, e_shoff + i * e_shentsize)
            for i in range(e_shnum)
        ]
        shstr = self.sections[e_shstrndx]
        shstrtab = bytes(d[shstr[4]:shstr[4] + shstr[5]])

        def name_at(off):
            end = shstrtab.index(b'\0', off)
            return shstrtab[off:end].decode()

        self.by_name = {name_at(s[0]): s for s in self.sections}
        for required in ('.dynamic', '.dynstr'):
            if required not in self.by_name:
                raise ValueError(f'{path}: missing {required} section')
        self.dyn = self.by_name['.dynamic']
        self.dynstr = self.by_name['.dynstr']
        self.dynstr_bytes = bytes(
            d[self.dynstr[4]:self.dynstr[4] + self.dynstr[5]]
        )
        if self.dyn[4] == 0:
            # .dynamic has no file offset (should not happen for a .node); the
            # dynstr VMA would be needed. Fail loudly instead of corrupting.
            raise ValueError(f'{path}: .dynamic has no file offset')

    # -- reading ------------------------------------------------------------
    def entries(self):
        """Yield (index, tag, value) for every non-NULL .dynamic entry."""
        d = self.data
        entsize = 16
        count = self.dyn[5] // entsize
        for i in range(count):
            off = self.dyn[4] + i * entsize
            tag, val = struct.unpack_from('<qQ', d, off)
            if tag == DT_NULL:
                break
            yield i, tag, val

    def str_at(self, off):
        end = self.dynstr_bytes.index(b'\0', off)
        return self.dynstr_bytes[off:end].decode()

    def needed(self):
        out = []
        for i, tag, val in self.entries():
            if tag in TAG_NAMES:
                out.append((i, tag, val, self.str_at(val)))
        return out

    # -- writing ------------------------------------------------------------
    def replace_string(self, old, new):
        """Rewrite a .dynstr string in place, NUL padded. Returns True on hit."""
        if len(new) > len(old):
            raise ValueError(
                f'cannot grow .dynstr in place: {old!r} ({len(old)}) -> '
                f'{new!r} ({len(new)})'
            )
        haystack = self.dynstr_bytes
        start = 0
        while True:
            idx = haystack.find(old.encode() + b'\0', start)
            if idx < 0:
                return False
            # Only rewrite string-table entries that start a string.
            if idx == 0 or haystack[idx - 1] == 0:
                padded = new.encode().ljust(len(old), b'\0')
                file_off = self.dynstr[4] + idx
                self.data[file_off:file_off + len(old)] = padded
                self.dynstr_bytes = bytes(
                    self.data[self.dynstr[4]:self.dynstr[4] + self.dynstr[5]]
                )
                return True
            start = idx + 1

    def write(self, path=None):
        with open(path or self.path, 'wb') as fh:
            fh.write(self.data)


def parse_pairs(pairs):
    out = []
    for item in pairs:
        if '=' not in item:
            raise SystemExit(f'--needed expects old=new, got {item!r}')
        old, new = item.split('=', 1)
        out.append((old, new))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('file', help='ELF64 shared object to patch (in place)')
    ap.add_argument('--print', action='store_true',
                    help='print the current dynamic entries and exit')
    ap.add_argument('--needed', action='append', default=[],
                    metavar='OLD=NEW',
                    help='replace a DT_NEEDED entry (repeatable)')
    ap.add_argument('--restore', action='store_true',
                    help='restore <file>.orig over <file> and exit')
    args = ap.parse_args()

    path = args.file
    if not os.path.exists(path):
        raise SystemExit(f'no such file: {path}')

    if args.restore:
        if not os.path.exists(path + '.orig'):
            raise SystemExit(f'no backup at {path}.orig')
        shutil.copyfile(path + '.orig', path)
        print(f'restored {path} from {path}.orig')
        return 0

    elf = Elf(path)

    if args.print or not args.needed:
        print(os.path.basename(path))
        for _, tag, val, name in elf.needed():
            print(f'  {TAG_NAMES[tag]:>6}  {name}')
        return 0

    # Keep an untouched copy so --restore (and re-patching) stays possible.
    orig = path + '.orig'
    if not os.path.exists(orig):
        shutil.copyfile(path, orig)

    changed = False
    for old, new in parse_pairs(args.needed):
        names = [n for _, _, _, n in elf.needed()]
        if new in names:
            print(f'  = {new} already a DT_NEEDED entry')
            continue
        if old not in names:
            print(f'  ! {old} is not a DT_NEEDED entry — skipped')
            continue
        if elf.replace_string(old, new):
            print(f'  ✓ {old} -> {new}')
            changed = True
        else:
            print(f'  ! {old} not found in .dynstr')

    if not changed:
        print('nothing to do')
        return 2

    elf.write()
    print(f'patched {path}')
    print('  resulting entries:')
    for _, tag, val, name in Elf(path).needed():
        print(f'    {TAG_NAMES[tag]:>6}  {name}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
