#!/usr/bin/env bash
# Print the directory holding an OpenSSL 1.x libssl for PkgTool.Core.
#
# PkgTool.Core dlopens libssl.so.1.1 (or a 1.0 soname), never libssl.so.3, so
# current distributions need a private OpenSSL 1.1. Hosts keep it in different
# places; this is the one lookup the package scripts use. It accepts the same
# sonames as the bundle's make-pkg.sh (openssl1x_dir).
set -euo pipefail

usage() {
    cat <<EOF
usage: $0 [--export]

Prints \$PS4_PKGTOOL_OPENSSL_LIB when it is set (as make-pkg.sh does, without
checking it), else the first directory that holds libssl.so.1.1, libssl.so.1.0.2,
libssl.so.1.0.0 or libssl.so.10, from:
  \${XDG_CACHE_HOME:-~/.cache}/orbis-ports/openssl11/lib  (where make-pkg.sh fetches it)
  ~/.local/opt/openssl-1.1/lib
  /nix/store/*-openssl-1.1*/lib
  /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib64 /usr/local/lib /usr/lib
  the directories of 'ldconfig -p'
Exits 1, printing nothing, when none does; callers decide whether that is fatal.

  --export  print "export PS4_PKGTOOL_OPENSSL_LIB=DIR" for eval.
EOF
}

EXPORT=0
case ${1:-} in
    -h|--help) usage; exit 0 ;;
    --export) EXPORT=1 ;;
    "") ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

emit() {
    if [[ $EXPORT == 1 ]]; then
        printf 'export PS4_PKGTOOL_OPENSSL_LIB=%q\n' "$1"
    else
        printf '%s\n' "$1"
    fi
    exit 0
}

[[ -z ${PS4_PKGTOOL_OPENSSL_LIB:-} ]] || emit "$PS4_PKGTOOL_OPENSSL_LIB"

sonames=(libssl.so.1.1 libssl.so.1.0.2 libssl.so.1.0.0 libssl.so.10)
dirs=("${XDG_CACHE_HOME:-$HOME/.cache}/orbis-ports/openssl11/lib"
      "$HOME/.local/opt/openssl-1.1/lib"
      /nix/store/*-openssl-1.1*/lib
      /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib64 /usr/local/lib /usr/lib)
ldc=$(command -v ldconfig || true)
[[ -n $ldc ]] || ldc=$(ls /sbin/ldconfig /usr/sbin/ldconfig 2>/dev/null | head -n1 || true)
if [[ -n $ldc ]]; then
    # "libssl.so.1.1 (libc6,x86-64) => /usr/lib/x86_64-linux-gnu/libssl.so.1.1"
    listing=$("$ldc" -p 2>/dev/null || true)
    while read -r path; do
        dirs+=("$(dirname "$path")")
    done < <(sed -n 's/^[[:space:]]*libssl\.so\.\(1\.1\|1\.0\.2\|1\.0\.0\|10\) .*x86-64.*=> //p' <<<"$listing")
fi
for dir in "${dirs[@]}"; do
    [[ -d $dir ]] || continue   # an unmatched /nix/store glob arrives here literally
    for soname in "${sonames[@]}"; do
        [[ -e $dir/$soname ]] && emit "$dir"
    done
done
exit 1
