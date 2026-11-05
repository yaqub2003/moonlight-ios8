#!/usr/bin/env python3
"""
Check that a Mach-O executable only has non-weak imports that exist on old iOS.

If an app imports a symbol (non-weakly) that the OS doesn't have, dyld kills
it at launch with "Symbol not found". The compiler's availability warnings
catch this for our own code, but not for prebuilt/third-party code, so as a
safety net every non-weak undefined symbol is looked up in the .tbd stubs of
an old SDK (iOS 9.3, the oldest one that ships .tbd files).

usage: check_symbols.py <llvm-nm> <old SDK dir> <executable>
"""

import os
import re
import subprocess
import sys

TOKEN = re.compile(r"[_$A-Za-z][\w$.]*")

# Basic libSystem routines that every iOS version has, but which the iOS 9.3
# .tbd files don't list (libsystem_platform exports them as _platform_*
# aliases, and libunwind's stub is incomplete).
ALWAYS_AVAILABLE = {
    "__Unwind_Resume", "_bcmp", "_bcopy", "_bzero",
    "_memccpy", "_memchr", "_memcmp", "_memcpy", "_memmove", "_memset",
    "_memset_pattern4", "_memset_pattern8", "_memset_pattern16",
    "_strchr", "_strcmp", "_strncmp", "_strlen", "_strnlen",
    "_strcpy", "_strncpy", "_strstr", "_strrchr",
}


def load_tbd_symbols(sdk):
    symbols = set()
    for dirpath, _, filenames in os.walk(sdk):
        for name in filenames:
            if not name.endswith(".tbd"):
                continue
            with open(os.path.join(dirpath, name), errors="replace") as f:
                text = f.read()
            for match in re.finditer(r"(symbols|weak-def-symbols|thread-local-symbols|objc-classes|objc-eh-types|objc-ivars|re-exports)\s*:\s*\[([^\]]*)\]", text, re.S):
                kind, body = match.group(1), match.group(2)
                for token in TOKEN.findall(body):
                    token = token.strip("'\"")
                    if kind == "objc-classes":
                        base = token if token.startswith("_") else "_" + token
                        symbols.add("_OBJC_CLASS_$" + base)
                        symbols.add("_OBJC_METACLASS_$" + base)
                    elif kind == "objc-eh-types":
                        base = token if token.startswith("_") else "_" + token
                        symbols.add("_OBJC_EHTYPE_$" + base)
                    elif kind == "objc-ivars":
                        base = token if token.startswith("_") else "_" + token
                        symbols.add("_OBJC_IVAR_$" + base)
                    else:
                        symbols.add(token)
    return symbols


def main():
    nm, sdk, binary = sys.argv[1:4]
    if not os.path.isdir(sdk):
        print("warning: %s not found, skipping symbol check" % sdk)
        return 0

    known = load_tbd_symbols(sdk) | ALWAYS_AVAILABLE
    output = subprocess.run([nm, "-m", "-u", binary], check=True,
                            capture_output=True, text=True).stdout

    missing = []
    for line in output.splitlines():
        line = line.strip()
        if not line or "weak" in line.split("external")[0]:
            continue
        # "(undefined) external _foo (from libSystem)"
        m = re.search(r"external (\S+)", line)
        if not m:
            continue
        symbol = m.group(1)
        if symbol not in known:
            missing.append(line)

    if missing:
        print("error: %s imports symbols that don't exist on iOS 9.3 and older:" % binary)
        for line in missing:
            print("  " + line)
        print("These would make the app crash at launch on iOS 8.")
        return 1

    print("Symbol check passed for %s" % binary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
