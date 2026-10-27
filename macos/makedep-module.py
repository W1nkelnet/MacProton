#!/usr/bin/env python3
"""Generate a makedep Makefile for an out-of-tree Wine module on macOS.

Equivalent of make/rules-makedep.mk, which relies on GNU sed and the Linux
build container. Takes the variable header of a configured Wine build tree,
points it at the module source and switches the C++ compilers to the ones
needed on macOS. Run Wine's tools/makedep in the output directory afterwards.

usage: makedep-module.py WINE_SRC WINE_BUILD MODULE_SRC OBJ_DIR
"""

import os
import sys


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    wine_src, wine_build, module_src, obj_dir = (os.path.abspath(a) for a in sys.argv[1:])

    lines = open(os.path.join(wine_build, 'Makefile')).read().split('\n')
    header = lines[:lines.index('all:')]

    inc = f'-I{wine_src}/include -I{wine_build}/include'
    replace = {
        'TOP_INSTALL_LIB': 'TOP_INSTALL_LIB =',
        'prefix': f'prefix = {obj_dir}/install',
        'libdir': f'libdir = {obj_dir}/install/lib',
        'toolsdir': f'toolsdir = {wine_build}',
        'CFLAGS': f'CFLAGS = {inc} -g -O2',
        'CPPFLAGS': f'CPPFLAGS = {inc}',
        # Wine's configure picks "g++", which is Apple clang building for the
        # host architecture; unix code has to be x86_64 like the rest of Wine
        'CXX': 'CXX = clang++ -arch x86_64 -m64',
        'CXXFLAGS': f'CXXFLAGS = {inc} -std=c++17 -g -O2',
        'x86_64_CFLAGS': f'x86_64_CFLAGS = {inc} -g -O2',
        'x86_64_CPPFLAGS': f'x86_64_CPPFLAGS = {inc}',
        'x86_64_CXXFLAGS': f'x86_64_CXXFLAGS = {inc} -std=c++17 -g -O2',
        'i386_CFLAGS': f'i386_CFLAGS = {inc} -g -O2',
        'i386_CPPFLAGS': f'i386_CPPFLAGS = {inc}',
        'i386_CXXFLAGS': f'i386_CXXFLAGS = {inc} -std=c++17 -g -O2',
    }
    append = {
        'srcdir': f'objdir = {wine_build}',
        'x86_64_CC': 'x86_64_CXX = x86_64-w64-mingw32-g++',
        'i386_CC': 'i386_CXX = i686-w64-mingw32-g++',
    }

    out = [f'UNIX_LIBS = {wine_build}/dlls/ntdll/ntdll.so', '']
    continued = False
    for line in header:
        if continued:
            continued = line.endswith('\\')
            continue
        name = line.split('=', 1)[0].strip() if '=' in line else None
        if name == 'SUBDIRS':
            out.append(f'SUBDIRS = {module_src}')
            continued = line.endswith('\\')
            continue
        out.append(replace.get(name, line))
        if name in append:
            out.append(append[name])
    out.append('all:')

    os.makedirs(obj_dir, exist_ok=True)
    with open(os.path.join(obj_dir, 'Makefile'), 'w') as f:
        f.write('\n'.join(out) + '\n')
    open(os.path.join(obj_dir, 'config.status'), 'a').close()


if __name__ == '__main__':
    main()
