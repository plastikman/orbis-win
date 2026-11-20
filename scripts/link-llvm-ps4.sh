#!/usr/bin/env bash
# Link the LLVM 19 tools the PS4 build calls by their plain names into
# build/ps4-wine-sdk/bin, next to the prospero-clang shim.
#
# The shim puts its own directory first on PATH and calls "clang" and, through
# clang's PS4 driver, "orbis-ld". radv-prx-ps4.sh and the PRX scripts call
# llvm-nm, llvm-ar, llvm-objcopy and the rest by plain name. Release builds pin
# LLVM/Clang 19 (19.1.7 in .github/workflows/build-ps4-package.yml): the
# validated wow64native hash pair was built with it. Distributions install it
# under versioned names (clang-19) or in a private directory
# (/usr/lib/llvm-19/bin), so the plain names may be missing or a different
# major version.
set -euo pipefail

usage() {
    cat <<EOF
usage: $0 [--llvm-bin DIR] [--check]

Links clang, clang++, ld.lld, orbis-ld (-> ld.lld) and the llvm-* tools from an
LLVM 19 bin directory into build/ps4-wine-sdk/bin.

  --llvm-bin DIR  LLVM 19 bin directory. Default: \$PW_LLVM_BIN, else
                  \`llvm-config-19 --bindir\`, else /usr/lib/llvm-19/bin, else
                  the directory of a clang on PATH that reports version 19.
  --check         only report whether the links exist and point at LLVM 19.

Without --llvm-bin or PW_LLVM_BIN, a bin directory that already holds a
complete, working LLVM 19 set is left as it is. Existing regular files there
are never replaced, only missing tools and symlinks.

Put build/ps4-wine-sdk/bin first on PATH for builds that call the tools
directly (orbis-compat's build.sh, Mesa's meson cross file).
EOF
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BIN="$ROOT/build/ps4-wine-sdk/bin"
LLVM_BIN=${PW_LLVM_BIN:-}
EXPLICIT=0
[[ -z $LLVM_BIN ]] || EXPLICIT=1
CHECK=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --llvm-bin)
            if [[ $# -lt 2 ]]; then echo "--llvm-bin needs a directory" >&2; usage >&2; exit 2; fi
            LLVM_BIN=$2; EXPLICIT=1; shift 2 ;;
        --check) CHECK=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

TOOLS=(clang clang++ ld.lld llvm-ar llvm-ranlib llvm-nm llvm-objcopy llvm-objdump
       llvm-readelf llvm-strip llvm-addr2line)

major() { { "$1" --version 2>/dev/null || true; } | sed -n 's/.*clang version \([0-9][0-9]*\)\..*/\1/p' | head -n1; }

# 0 when $BIN holds every tool, each runnable, and clang is major 19. Says what
# is wrong on stderr when $1 is "say".
bin_complete() {
    local bad=0 t m
    for t in "${TOOLS[@]}" orbis-ld; do
        [[ -x $BIN/$t ]] || { [[ ${1:-} == say ]] && echo "missing: $BIN/$t" >&2; bad=1; }
    done
    if [[ $bad == 0 ]]; then
        m=$(major "$BIN/clang")
        [[ $m == 19 ]] || { [[ ${1:-} == say ]] && echo "$BIN/clang is clang ${m:-?}, not 19" >&2; bad=1; }
    fi
    return $bad
}

if [[ $CHECK == 1 ]]; then
    bin_complete say || exit 1
    echo "llvm: $BIN -> $(readlink -f "$BIN/clang") ($("$BIN/clang" --version | head -n1))"
    exit 0
fi

# A setup that already works stays as it is, unless a directory was named.
if [[ $EXPLICIT == 0 ]] && bin_complete; then
    echo "llvm: $BIN already holds LLVM 19 ($("$BIN/clang" --version | head -n1)); not relinked"
    exit 0
fi

if [[ -z $LLVM_BIN ]]; then
    if command -v llvm-config-19 >/dev/null 2>&1; then
        LLVM_BIN=$(llvm-config-19 --bindir)
    elif [[ -x /usr/lib/llvm-19/bin/clang ]]; then
        LLVM_BIN=/usr/lib/llvm-19/bin
    else
        # A clang on PATH, or a clang-19, that really is 19, with the other
        # tools beside it.
        for c in clang clang-19; do
            p=$(command -v "$c" 2>/dev/null || true)
            [[ -n $p && $(major "$p") == 19 ]] || continue
            [[ $p -ef $BIN/clang ]] && continue    # this directory's own link
            LLVM_BIN=$(dirname "$p")
            break
        done
    fi
fi
[[ -n $LLVM_BIN ]] || { echo "no LLVM 19 found (install clang-19 lld-19 llvm-19, or pass --llvm-bin)" >&2; exit 1; }
abs=$(cd "$LLVM_BIN" 2>/dev/null && pwd -P) || { echo "no such directory: $LLVM_BIN" >&2; exit 1; }
LLVM_BIN=$abs

[[ -x $LLVM_BIN/clang ]] || { echo "no clang in $LLVM_BIN (install clang-19 lld-19 llvm-19, or pass --llvm-bin)" >&2; exit 1; }
m=$(major "$LLVM_BIN/clang")
[[ $m == 19 ]] || { echo "$LLVM_BIN/clang is clang ${m:-?}; the release build pins 19" >&2; exit 1; }
for t in "${TOOLS[@]}"; do
    [[ -x $LLVM_BIN/$t ]] || { echo "missing $LLVM_BIN/$t" >&2; exit 1; }
done

mkdir -p "$BIN"
link() { # target name
    if [[ -e $BIN/$2 && ! -L $BIN/$2 ]]; then
        echo "kept: $BIN/$2 is a regular file" >&2
    else
        ln -sfn "$1" "$BIN/$2"
    fi
}
for t in "${TOOLS[@]}"; do link "$LLVM_BIN/$t" "$t"; done
link "$LLVM_BIN/ld.lld" orbis-ld
echo "llvm: $LLVM_BIN -> $BIN ($("$LLVM_BIN/clang" --version | head -n1))"
