# orbis-compat pin

The fourth unpinned build input, found 2026-11-17 while testing whether
GLDS10043 02.59 could be rebuilt exactly.

**What it decides.** `prepare-ps4-toolchain.sh` copies this archive to
`build/ps4-wine-sdk/liborbis-compat-16bit-wchar.a`, and every PRX links it.
Which copy you use changes the bytes of every module.

| copy | size | defines `orbis_jit_alloc` / `orbis_report` |
|---|---|---|
| the fetched SDK bundle's | 114,252 B | **no** |
| the one 02.59 linked | 190,196 B | yes |

The parity gate had been reporting the difference for weeks as
*"PS4-specific baseline strings missing; review each"*. It was not cosmetic.

**Upstream is public but archived**: `orbis-ports/orbis-compat` at
`6922a7b6f` ("docs: archived, superseded by orbsdk"), plus the delta here
(`include/signal.h`, 61 lines) and the `cmake/` directory, which is untracked
upstream.

    git clone https://github.com/orbis-ports/orbis-compat.git
    git -C orbis-compat checkout --detach 6922a7b6f
    git -C orbis-compat apply /path/to/orbis-compat-delta.patch
    cp -r cmake orbis-compat/

Then build it and point the toolchain at it:

    PW_ORBIS_COMPAT=/path/to/orbis-compat ./scripts/prepare-ps4-toolchain.sh

`prepare-ps4-toolchain.sh` prints the archive's hash, so a build records which
one it linked.

**You do not need this to build.** A package built against the SDK bundle's
copy passes the parity gate (verified 2026-11-17: 19 PASS, 0 FAIL). Use this pin
when you want the `orbis_*` diagnostics, or when comparing against an older
package.
