#!/bin/sh
# Run OpenOrbis create-fself on a copy of its -in ELF with .comment and
# .debug_* removed, so the package does not depend on which build of the
# compiler made it.
#
#   create-fself-repro.sh <path/to/create-fself> <create-fself arguments...>
#
# create-fself writes digests of the WHOLE input ELF into the fself header,
# including sections that are never loaded. .comment carries the compiler and
# linker identity ("Debian clang version 19.1.7 (3+b1)" on the workstation,
# "Ubuntu clang version 19.1.7 (++2025...)" on the CI runner), and .debug_*
# carries the build directory. CI run 42144084165 (2026-11-05) produced code
# and data byte-identical to the workstation's in every module, and still a
# different .prx in every module because of those two.
#
# create-fself also embeds the -in path as given (an eboot carried
# "/home/zpeirce/codex_scratch/candidate-a-0114/build/stub.elf"), and the CI
# runner builds under another directory. So the stripped copy is made under
# its own name in a scratch directory beside the input, and create-fself runs
# from there with a bare file name; every other path argument is made
# absolute first. The output is then the same wherever the build ran.
#
# The caller's ELF is left untouched: it keeps its debug info for
# llvm-addr2line, and its loaded content is exactly what the .prx contains.
set -eu
tool=$1
shift

in=
prev=
for a do
    [ "$prev" = -in ] && in=$a
    case $a in -in=*) in=${a#-in=} ;; esac
    prev=$a
done
[ -n "$in" ] || exec "$tool" "$@"

abs() { case $1 in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
in=$(abs "$in")
work=$(dirname -- "$in")/.fself-repro.$$
name=$(basename -- "$in")
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT
"${LLVM_OBJCOPY:-llvm-objcopy}" --wildcard --remove-section=.comment \
    --remove-section='.debug_*' "$in" "$work/$name"

prev=
for a do
    shift
    case $prev in
    -in) a=$name ;;
    -out|-lib|-eboot) a=$(abs "$a") ;;
    -library-path)
        lp=
        old_ifs=$IFS; IFS=:
        for d in $a; do lp=${lp:+$lp:}$(abs "$d"); done
        IFS=$old_ifs
        a=$lp ;;
    esac
    case $a in
    -in=*) a=-in=$name ;;
    -out=*|-lib=*|-eboot=*) a=${a%%=*}=$(abs "${a#*=}") ;;
    esac
    prev=${a%%=*}
    [ "$prev" = "$a" ] || prev=
    set -- "$@" "$a"
done

cd "$work"
"$tool" "$@"
