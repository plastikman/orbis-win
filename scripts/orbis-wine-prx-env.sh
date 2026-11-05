#!/bin/sh
# Build environment for the split checkout's Orbis Wine PRXs.
#
# Source this, then run the split checkout's tools/build_wine_orbis_prx.sh to
# rebuild sce_module/*.prx. These values are not recorded anywhere else; they
# were reconstructed on 2026-10-14 and validated by rebuilding the unmodified
# tree, which reproduced nine of the ten PRXs byte for byte. The tenth,
# win32u.prx, differed in 44 bytes of fself container header out of 2,854,832
# -- build metadata, no code -- so a change to one source file yields a package
# that differs from its A/B base in that one PRX alone.
#
#   . scripts/orbis-wine-prx-env.sh
#   cd $SCRATCH_ROOT/prospero-win-orbis-upstream
#   ./tools/build_wine_orbis_prx.sh
#
# The PRX tree is .deps/wine-orbis-full-legacy, NOT .deps/wine-orbis: the
# working packages' PRXs come from the legacy tree. Check before assuming.
G=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PROSPERO_WIN_ROOT=${PROSPERO_WIN_ROOT:-$G/prospero-win}
WINE_WORK=${ORBIS_WINE_WORK:-$PROSPERO_WIN_ROOT/.deps/wine-orbis-full-legacy}
export ORBIS_SDK=$G/sdk/orbis-sdk-v1/sdk
export ORBIS_COMPAT_INCLUDE=$G/sdk/orbis-sdk-v1/orbis-compat/include
export ORBIS_COMPAT_LIB=$G/sdk/orbis-sdk-v1/orbis-compat/build/liborbis-compat.a
export ORBIS_LINKER_SCRIPT=$G/mesa-build/orbis-porting-kit/cmake/orbis-tls.ld
export ORBIS_TOOLCHAIN_BIN=$G/build/ps4-wine-sdk/bin
export ORBIS_PRX_WCHAR_COMPAT_LIB=$G/build/ps4-wine-sdk/liborbis-compat-16bit-wchar.a
export ORBIS_PRX_EH_FRAME_LD=$PROSPERO_WIN_ROOT/wine/ps5/prx_eh_frame.ld
export ORBIS_PRX_MODULE_PARAM_LD=$G/src/freebsd-compat/prx_module_param.ld
export ORBIS_PRX_INIT_ARRAY_LD=$G/src/freebsd-compat/prx_init_array.ld
export ORBIS_PRX_MODULE_PARAM_OBJ=$G/build/ps4-wine-sdk/module_param.o
export ORBIS_PROSPERO_COMPAT=1
export ORBIS_WINE_WORK="$WINE_WORK"
export ORBIS_JOBS=${ORBIS_JOBS:-4}
