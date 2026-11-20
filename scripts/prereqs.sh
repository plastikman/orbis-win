#!/usr/bin/env bash
# What this host needs to cross-build for the PS4, and whether it has it.
# Checks only. Prints the install command rather than running it.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# clang/clang++/llvm-ar/llvm-ranlib/ld.lld: the SDK ships no compiler. libc and
# libc++ are prebuilt in the bundle; the host supplies the toolchain that uses them.
# glslangValidator: the triangle compiles SPIR-V on the host and embeds it, so the
# console reads no shader files. lftp: deploy.sh's transport.
# ⚠ THIS LIST IS WHAT A CLEAN MACHINE ACTUALLY NEEDS, not what one workstation
# happened to have. Every entry after lftp was found by running the from-source
# build on a GitHub runner, where each missing one failed hours in with a
# message that did not name it -- "configure failed; see configure.log", or
# "'sys/ioccom.h' file not found". Checking here costs a second and saves that.
TOOLS=(clang clang++ llvm-ar llvm-ranlib ld.lld cmake ninja glslangValidator lftp
       x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc bison flex perl pkg-config nix)
APT=(clang lld llvm cmake ninja-build glslang-tools lftp
     gcc-mingw-w64-x86-64 gcc-mingw-w64-i686 g++-mingw-w64-i686
     bison flex perl pkg-config build-essential
     libx11-dev libxext-dev libxrandr-dev libxi-dev libxcursor-dev
     libxcomposite-dev libxinerama-dev libxrender-dev libxfixes-dev
     libfreetype-dev libfontconfig1-dev libgnutls28-dev libvulkan-dev
     libasound2-dev nix-setup-systemd)

missing=0
for t in "${TOOLS[@]}"; do
  if p=$(command -v "$t" 2>/dev/null); then
    printf '  %-18s %s\n' "$t" "$p"
  else
    printf '  %-18s MISSING\n' "$t"; missing=$((missing + 1))
  fi
done

echo
if (( missing )); then
  echo "$missing missing. On Debian/Ubuntu:"
  echo
  echo "    sudo apt-get install -y ${APT[*]}"
  exit 1
fi

# The bundle was cut against LLVM 18. Clang 19 builds it clean (verified
# 2026-10-06 on Debian 13 — hello, triangle and a packaged .pkg). Newer is
# untested, so say so rather than failing on it.
ver=$(clang --version | sed -n '1s/.*version \([0-9]*\).*/\1/p')
[[ -n $ver && $ver -ge 20 ]] &&
  echo "note: clang $ver — the bundle targets LLVM 18 and is verified on 19. Untested here."

# Wine's host configure wants X11 and friends. They have no binary on PATH to
# probe, so check one header of each instead of pretending the tool list covers
# it: without them configure fails with "X 64-bit development files not found".
devmissing=0
for h in /usr/include/X11/Xlib.h /usr/include/freetype2/ft2build.h \
         /usr/include/fontconfig/fontconfig.h; do
    [[ -f $h ]] || { printf '  %-18s MISSING (%s)\n' "dev headers" "$h"; devmissing=1; }
done
if (( devmissing )); then
    echo
    echo "Wine's host build needs development headers. On Debian/Ubuntu:"
    echo
    echo "    sudo apt-get install -y ${APT[*]}"
    exit 1
fi

# nix is a hard requirement of the Mesa build (build-support/orbis/build.sh
# refuses without it) and needs a group membership, which an install alone does
# not give you.
if command -v nix >/dev/null && ! id -nG | tr " " "\n" | grep -qx nix-users; then
    echo "note: nix is installed but you are not in nix-users;" \
         "the Mesa build will fail with 'daemon-socket/socket: Permission denied'."
    echo "      sudo usermod -aG nix-users \"$USER\"   (then log out and back in)"
fi

say "host is ready"
