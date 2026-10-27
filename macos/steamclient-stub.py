#!/usr/bin/env python3
"""Generate the steamclient stub DLL sources from lsteamclient.spec.

The game's steam_api loads steamclient.dll/steamclient64.dll from SteamPath.
Wine's loader redirects every named export of a module with that name to the
export of the same name in lsteamclient.dll (steamclient_setup_trampolines).
On Linux Steam ships the Windows steamclient DLLs; macOS Steam does not, so
this builds a minimal non-builtin DLL exporting the same names.

Each export is padded to 32 bytes: the redirect overwrites the start of every
exported function with a jump of up to 14 bytes.

usage: steamclient-stub.py SPEC ARCH OUT_PREFIX
  ARCH is x86_64 or i386; writes OUT_PREFIX.S and OUT_PREFIX.def
"""

import sys


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    spec, arch, out = sys.argv[1:]
    prefix = '_' if arch == 'i386' else ''

    names = []
    for line in open(spec):
        fields = line.split()
        if len(fields) < 3 or fields[0].startswith('#'):
            continue
        flags = [f for f in fields[2:] if f.startswith('-')]
        # private exports are Proton internals, not part of the Steam API
        if '-private' in flags:
            continue
        names.append(next(f for f in fields[2:] if not f.startswith('-')).split('(')[0])

    with open(out + '.S', 'w') as f:
        f.write('\t.text\n')
        # DllMain(hinst, reason, reserved): return TRUE
        f.write(f'\t.globl {prefix}DllMain\n{prefix}DllMain:\n\tmov $1, %eax\n')
        f.write('\tret $12\n' if arch == 'i386' else '\tret\n')
        for name in names:
            f.write(f'\t.balign 32\n\t.globl {prefix}{name}\n{prefix}{name}:\n')
            f.write('\txor %eax, %eax\n\tret\n\t.fill 28, 1, 0xcc\n')

    with open(out + '.def', 'w') as f:
        f.write('EXPORTS\n')
        for name in names:
            f.write(f'\t{name}\n')


if __name__ == '__main__':
    main()
