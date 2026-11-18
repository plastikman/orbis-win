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

**YOU DO NEED THIS TO BUILD.** An earlier version of this file said you did
not, on the evidence that a package built against the SDK bundle's copy passes
the parity gate (19 PASS, 0 FAIL). It does pass -- and it is still broken.

Measured on hardware 2026-11-17. The bundle's `include/signal.h` predates the
delta below, so `SIG_UNBLOCK` compiles to Linux's `1`, which libkernel reads as
`SIG_BLOCK`. Wine's `pw_native_frame_verified()` probe then blocks the very
signal it is about to send itself:

    err:seh:pw_native_frame_verified PW_NATIVE_FRAME unverified sig=28
      ... old_blocked=0 ... now_blocked=1 ... pending=1 ... hits=0

The handler never runs, the probe fails, `pw_native_ready_caps()` returns 0,
`wow64native`'s `process_init` returns `STATUS_NOT_SUPPORTED` (`c00000bb`), and
Wine falls back to the `wowprospero` translator **silently**. Every title then
runs at translator speed. The delta also corrects the signal *numbers*
(`SIGUSR1=30`, `SIGBUS=10`, `SIGSYS=12`, ...), without which a SIGBUS fault can
be mistaken for Wine's SIGUSR1 suspend signal.

`src/toolchain/prospero-clang` now refuses to build without an orbis-compat
carrying this delta, rather than silently selecting the bundle's copy.

The `orbis_*` diagnostics are a second, lesser reason to use the pin.
