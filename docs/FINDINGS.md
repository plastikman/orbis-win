# Findings

Newest last. Things that cost time, and what settled them.

---

## 2026-10-06 — Stage 1 host chain works end to end

Debian 13 (trixie), `clang 19.1.7`. Built `hello` and `triangle` from
`orbis-sdk-v1` and produced installable `.pkg` files for both. Nothing has been
near the console yet — this is the host half of stage 1 only.

| | eboot.bin | .pkg |
|---|---|---|
| `hello` | 660 KB | 5.8 MB |
| `triangle` | 25 MB | 26 MB |

The size gap is the whole Vulkan driver. `triangle`'s ELF carries **1,782**
`radv_*` / `ac_drm_*` / `aco_*` symbols, which is the cheapest proof that Mesa
actually linked rather than silently falling out of the link line.

Bundle checksum, as downloaded:

```
f4f079a4df334b46a76996f895283904283d6a006f97102aafaa53d4ecfc9622  orbis-sdk-v1.tar.gz
```

### clang 19 builds an LLVM-18 bundle clean

`BUNDLE.txt` pins `openorbis-sdk-asset=toolchain-llvm-18.tar.gz`, so LLVM 18 is
the reference. Debian 13 ships 19 and there is no apt path to 18 here. It
builds, links and packages without a single diagnostic. The SDK ships libc and
libc++ prebuilt; the host compiler only compiles our code and drives `ld.lld`,
so the version coupling is looser than it looks.

**Not proven on hardware.** If the console behaves oddly in a way that smells
like codegen or TLS layout, this is the first thing to rule out, by pinning 18.

### ⚠ `gate=unproven` is a false warning — upstream bug

Every configure prints:

> `BUNDLE.txt says gate=unproven: nothing has been built from this bundle yet`

`BUNDLE.txt` line 31 says `gate=pass`. The check in `toolchain/orbis-sdk.cmake:47`
is a whole-file regex:

```cmake
file(READ "${ORBIS_SDK_BUNDLE}/BUNDLE.txt" _orbis_manifest)
if(_orbis_manifest MATCHES "gate=unproven")
```

and the comment three lines above the value reads *"A bundle carrying
gate=unproven is not publishable."* The regex matches the **comment**. It needs
line anchoring. Cosmetic, but it trains you to ignore warnings from that file,
which is the actual cost. `scripts/build.sh` filters this one block specifically
so a real warning still stands out.

### ⚠ `examples/triangle` does not build from the bundle alone

```
ORBIS_KIT_DIR=<bundle> holds no vkloader/
```

The example resolves `ORBIS_KIT_DIR` to `${CMAKE_CURRENT_LIST_DIR}/../..` — the
bundle root — and expects `vkloader/CMakeLists.txt` under it. The bundle has no
top-level `vkloader/`; it carries the same code at `orbis-compat/vkloader/`.
The example was written to live inside an `orbis-porting-kit` checkout, and the
bundle cut it loose from that.

Fix, which `scripts/build.sh` applies:

```sh
-DORBIS_KIT_DIR="$BUNDLE/orbis-compat"
```

The example's own comment says it deliberately wants *the kit's* vkloader rather
than orbis-compat's, so that the kit's copy is the one under test. That
distinction does not matter to us — we are not testing the kit — but it is why
the default points where it does.

### Two bugs of our own, both in the verification code

Worth recording because both produced a **failure report on a check that
passed**, which is the expensive direction.

1. **`grep -q` under `set -o pipefail`.** `llvm-nm … | grep -q _sceProcessParam`
   reported missing on an image that had it. `grep -q` exits at the first match,
   `llvm-nm` takes SIGPIPE, and `pipefail` surfaces the pipeline as failed. Now
   the symbol table is captured once into a variable and matched from there.
2. **`strtonum` is a gawk extension.** The PT_LOAD alignment check used it;
   Debian's `awk` is mawk. The hex conversion moved into the shell.

Both are the same shape as the pattern the upstream record keeps flagging:
*make the check print what it measured, not a verdict.*

---

## Open, for when the console is involved

- Nothing here has run on hardware. `gate=pass` means the bundle **builds**, not
  that it runs; the bundle's own README is explicit about that.
- `config.env` needs the real console IP. GoldHEN's FTP is usually 2121, but
  stock FTP payloads often use 1337 — check which one is listening.
- Start `scripts/logs.sh` before launching anything. There is no usable stdout
  on this platform (`freopen` fails), so a black screen with no listener is a
  wasted evening.

---

## 2026-10-06 — `RADV_DEBUG=info` cannot be set on this console, and the way round it

Stage 2 was written assuming we would capture `radeon_info` the way the upstream
record does: `RADV_DEBUG=info`, then `sed` the `radv-info|` lines out of the UDP
capture. Neither half of that works from a stock bundle.

### The dump has nowhere to go

`radeon_info` does not go through `mesa_log`, and on this platform it cannot go
through stdout either — `freopen` fails. Upstream's harness patches the one call
site to `fopen` a file directly. We have Mesa as **prebuilt static archives**, so
there is no call site to patch without rebuilding Mesa.

### ⚠ And the switch cannot be thrown at all

This is the more interesting half, and it is the exact failure
`orbis-compat/scripts/check-env-knobs.sh` exists to catch — *"a switch that
cannot be thrown looks exactly like a switch with no effect."*

`orbis-compat/src/orbis_env.cpp` reads `/data/orbis-env.txt`, but `load_file()`
calls `store()`, which writes into a **private array** (`g_entry[]`). It does not
`setenv()`. Only code calling `orbis_env_get()` ever sees those values.

Mesa reads its knobs with plain `getenv()` — `RADV_DEBUG`, and the PS4 port's own
`ORBIS_TESS_WORKGROUPS` and `ORBIS_TF_BASE_BIAS`. On a console `getenv` returns
NULL for all of them, the code takes its default, and **the run comes back looking
like a measurement of the default**. Stage 3's entire tuning method depends on
those two knobs, so this would have invalidated it silently.

The fix is small, and it works *here* for a reason worth stating: RADV is
statically linked into our eboot, so Mesa and our `main()` share one `environ`.
`setenv()` early in `main()`, before `vkCreateInstance`, and Mesa sees it.

That is also why it failed upstream for RetroArch: a `.prx` core links its own
copy of static musl with its own `environ`, and the frontend's `setenv` never
reached it. Measured upstream 2026-08-23 — `ORBIS_NCPU=1` was applied to the
eboot's environ and the core still started 5 workers.

`src/probe/probe.c` does the `setenv` pass and logs each setting it applied, so
the knob being thrown is visible in the capture rather than assumed.

### What replaces the radeon_info diff

`VK_AMD_shader_core_properties` is present in this bundle's RADV (confirmed by
`strings` on `libvulkan_radeon.a`) and carries the fields stage 3 actually
depends on:

| Vulkan field | radeon_info field | Liverpool |
|---|---|---|
| `shaderEngineCount` | `max_se` | 2 |
| `shaderArraysPerEngineCount` | `max_sa_per_se` | 1 |
| `computeUnitsPerShaderArray` | `num_cu_per_sh` | 9 |
| product of the three | `num_cu` | 18 |

Plus `VkPhysicalDeviceProperties.deviceID`, which is `0x9924` for `CHIP_GLADIUS`
in `ac_gpu_info.c` — the direct answer to whether the Pro branch fired — and
`deviceName`, which RADV fills from `ac_get_marketing_name`.

That is most of what the `radeon_info` diff was going to tell us, through a
standard extension, with no Mesa rebuild. It is not all 164 fields. If the full
dump turns out to be needed, the path is to rebuild Mesa from the `orbis` branch
with the log call site patched, which is a much larger job than this stage needs.

---

## 2026-10-06 — first contact with the console

Preflight passed cleanly against `$PS4_HOST`:

```
  console                `$PS4_HOST` up
  this host              `$BUILD_HOST` via eth0
  ftp 2121               220 GoldHEN FTP server v2.2
  ftp 1337               no answer
  ftp 21                 no answer
  klog 3232              open
  udp 18194              free
```

The upload then failed on all three packages, and by the time it was traced both
GoldHEN services — FTP **and** klog — had stopped listening while the console
still answered ping. A TCP probe does not take down klog, so this reads as
GoldHEN unloading rather than anything the probe did. Nothing was transferred.

**Unresolved.** If it recurs, the thing to establish is whether GoldHEN survives
between preflight and upload at all, and the cheap way to find that out is to
re-run preflight immediately after a failed deploy rather than minutes later.

### Two real bugs this shook out

**`preflight.sh` read 96 bytes where it should have read one line.** An FTP
server sends its greeting and then holds the connection open waiting for
commands, so `head -c 96` blocked until `timeout` killed it — exit 124, and
under `set -e` that took the whole script down after printing two lines. The
first version was tested against a fake server that closed immediately, so the
test never modelled the behaviour that matters. Now it reads a single line with
`read -t`, and the replacement was checked against a responder that *holds* the
socket open.

**`deploy.sh` was being handed a symlink and sizing that.** `make-pkg.sh` leaves
`<TITLE_ID>.pkg` pointing at the real `IV0000-…pkg`, and `deploy.sh` sizes its
argument with `stat -c%s`, which reports **40 bytes** for the link:

```
== 40 B  .../pkgout/triangle/GLDS10001.pkg
```

deploy.sh's entire verification is *compare what arrived against what was sent* —
written that way because this project has repeatedly had status codes report
success over failure. A 40-byte local size silently guts that check on the one
step it exists to protect. `build.sh` now resolves the link before handing it
over.

Neither bug was found by reasoning about the code. Both appeared the moment real
hardware was on the other end, which is the argument for stage 1 existing as its
own stage.

---

## 2026-10-06 — all three packages on the console

`/data/pkg/` now holds `hello.pkg` (6,619,136 B), `triangle.pkg` and `probe.pkg`
(27,394,048 B each), every one verified by reading the directory back rather
than by trusting the `226`.

### ⚠ lftp's login is what kills GoldHEN

Reported by the console's owner, who watched it happen: *"before you logged in
it worked, then once you logged in it died."* Twice, each costing a reboot.

`deploy.sh` passes no credentials, so lftp falls back to **anonymous**, and that
login takes down the whole GoldHEN payload — FTP and klog both — leaving a
console that still answers ping. I had been about to blame my own klog probe
instead, which does not fit the evidence at all: the owner's observation was
specific and the probe theory was a guess.

`scripts/ftp-put.py` replaces lftp on this path. It attempts **no login at all**
and sends only what STOR requires:

```
TYPE I  →  MKD  →  PASV  →  STOR
```

No FEAT, no SYST, no OPTS, no PWD, no EPSV, no SIZE, no MLSD. Every command and
reply is printed before it is sent, so a server that dies again names the
command that did it. Three uploads and a directory listing since, with the
server alive throughout.

### `/data/pkg/` does not exist on a fresh console

The bundle's `deploy.sh` says *"/data/pkg AND NOWHERE ELSE"* and assumes the
directory is there. On this console it was not, and STOR answered:

```
550 Requested action not taken. File unavailable.
```

`/data` is `drwxrwxrwx`, so `MKD /data/pkg` is enough. ftp-put.py now creates the
parent and ignores the reply — an existing directory answers 550 here too, so
checking it would be worse than not.

### ⚠ These examples log to KLOG, not to the UDP netlog

Both `triangle.c` and `probe.c` write through `sceKernelDebugOutText`, which is
GoldHEN's **klog** channel on TCP 3232. Neither calls `orbis_netlog`. So
`scripts/logs.sh` with no argument — the UDP path, and the one the plan kept
calling primary — captures nothing from either of them.

**`scripts/logs.sh klog` is the one to run**, and it must be left draining: the
console's stdout write *blocks the calling thread* when nothing is reading that
socket. That is also the reason preflight's connect-and-close klog check was a
bad idea regardless of whether it caused anything, and it has been removed.

---

## 2026-10-06 — `hello` crashed before `main()`: empty `sce_module/`

First launch on hardware. The klog named it exactly, which is the entire reason
for running `hello` before anything that touches Mesa:

```
# A user thread receives a fatal signal
# exception: 0xa0020102 (PRX_SCE_MODULE_LOAD_ERROR)
# thread name: eboot.bin
...
# === Lack of a .prx file in /app0/sce_module is detected!!! ===
# Copy the file (e.g. libc.prx) from target/sce_module.
```

Not a crash in our code — the process never reached `main`. `libkernel.sprx`,
`libSceLibcInternal.sprx`, `libSceSysmodule.sprx` and `libSceDiscMap.sprx` all
mapped; the loader then refused for want of `/app0/sce_module`.

### The package declared the directory and shipped nothing in it

`make-pkg.sh`'s gp4 carries `<dir targ_name="sce_module" />` under `rootdir`,
and its `<files>` list had only `eboot.bin` and `sce_sys/param.sfo`. The
OELF's own needs are modest — `readoelf -d` shows one `SCE_NEEDED_MODULE`,
`libkernel` — so the requirement comes from the loader's rules for an app
process, not from our link line.

### Where the modules come from

`libc.prx` and `libSceFios2.prx` are **Sony firmware modules**. The OpenOrbis
SDK ships no `.prx` at all, for the obvious reason, and neither does this
repository — `sce_module/` is gitignored and `sce_module/README.md` documents
extracting them from your own console.

Any installed OpenOrbis homebrew carries both. Here they came out of Apollo Save
Tool (`APOL00004`): `RETR /user/app/APOL00004/app.pkg` over the same FTP path,
then `PkgTool.Core pkg_extract`, and they land under `uroot/sce_module/`.

```
8ac205d14351edb241238b372b2f1c3350a6385a271483d4867fe9a33bc6e4d3  libc.prx          3424 B
905cf6b7c699eccb6b95291fc4dcaf5ce2d2605f450f36496d9b973777afa745  libSceFios2.prx   3200 B
```

Both are a few kilobytes — stubs that satisfy the loader, not implementations.
The real code is in `libSceLibcInternal.sprx`, which the process already maps.

⚠ `PkgTool.Core pkg_extract` needs the same OpenSSL 1.x shim and
`DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` that `make-pkg.sh` sets up, and
without them it prints `No usable version of libssl was found` **and exits 0** —
a failure that reads as a successful run with no output.

`build.sh` now refuses to package at all if either module is missing, rather
than building something that cannot boot.

Packages rebuilt and re-uploaded: triangle and probe grew 27,394,048 → 27,525,120 B.

---

## 2026-10-06 — RADV RENDERS ON THE PRO. And the Pro is running as a base PS4.

Stage 1 is done. `hello` prints and `triangle` draws:

```
orbis-sdk bundle: hello
orbis-sdk bundle: all checks passed

orbis-sdk bundle: triangle
triangle: ok   vkCreateInstance
triangle: ok   vkCreateHeadlessSurfaceEXT
triangle: GPU 'PlayStation 4 Liverpool (RADV ORBIS) (RADV LIVERPOOL)', api 1.3.359, driver 0x06802063
triangle: queue family 0 renders and presents
triangle: ok   vkCreateDevice
triangle: surface 1920x1080, format 37, 4..0 images
triangle: ok   vkCreateSwapchainKHR    ... swapchain has 4 images
triangle: ok   vkCreateGraphicsPipelines
triangle: setup complete - presenting
triangle: frame 1024 presented
```

Every call checked and named, a pipeline compiled from SPIR-V, 1024+ frames at
1920x1080. **`api 1.3.359` — Vulkan 1.3**, not the 1.1 the gfx7 framing led me
to expect.

⚠ `hello`'s black screen is CORRECT and I should have said so in advance. Both
examples end in `for (;;) sleep(1)` deliberately: returning from `main()` on this
console is reported as CE-34878-0 and reads exactly like a crash. `hello` draws
nothing, so black is the right picture.

### The probe's answer: 18 compute units, device id 0x9920

```
probe: 197 device extensions, VK_AMD_shader_core_properties present
deviceName        PlayStation 4 Liverpool (RADV ORBIS) (RADV LIVERPOOL)
vendorID          0x1002
deviceID          0x9920
shaderEngineCount        2      <- max_se
shaderArraysPerEngine    1      <- max_sa_per_se
computeUnitsPerShaderArr 9      <- num_cu_per_sh
=> compute units         18
simdPerComputeUnit       4   wavefrontsPerSimd 10   wavefrontSize 64
heap 0  661 MB host      heap 1  1322 MB device-local
family 0  1 queue(s) graphics compute transfer
```

`ac_gpu_info.c` maps `0x9920/0x9922/0x9923 -> CHIP_LIVERPOOL` and `0x9924 ->
CHIP_GLADIUS`. The console answered **0x9920**, and the topology is exactly the
Liverpool baseline — 2 SE, 1 SA, 9 CU/SA.

**This is not a driver bug. The title was never given the Pro.**

### ⚠ Root cause: param.sfo ATTRIBUTE bit 24

A PS4 Pro runs a title in base-PS4 compatibility mode unless the title declares
NEO support: `param.sfo` `ATTRIBUTE` flag 24, `0x00800000` (8388608). In base
mode the extra compute array is simply not there to be enumerated — the GPU
answers Liverpool's device id and reports 18 CUs, which is precisely what we
measured.

`make-pkg.sh` writes `sfo_set ATTRIBUTE Integer 4 0`. Every package this project
has built so far has been a base-PS4 package.

`build.sh --neo` now sets it. make-pkg.sh takes no `--attribute`, so the staged
SFO is edited afterwards and the package rebuilt from the gp4 make-pkg.sh
already wrote — reusing its file list rather than composing a second one.

Verified by parsing the SFO out of the uploaded package's bytes rather than
trusting the tool, because `PkgTool.Core` has already been seen to fail and exit
0 once this session:

```
param.sfo magic at 0x3db0
  APP_TYPE     = 0x1
  ATTRIBUTE    = 0x800000
  TITLE_ID     = GLDS10002
```

⚠ `pkg_extract` will not show you this: it unpacks the inner PFS (`uroot/`)
only, and `param.sfo` is a PKG entry rather than a PFS file.

The SDK also exposes `sceKernelHasNeoMode()` (is the CONSOLE a Pro) and
`sceKernelIsNeoMode()` (did THIS TITLE get Neo mode). probe.c now prints both,
so the next run distinguishes "package was wrong" from anything else.

### Still unknown

Whether the attribute alone is sufficient. It may also need the eboot built with
a Neo flag, or an explicit `sceKernelSwitchToNeoMode()` call. The two
`sceKernel*NeoMode` readings will say which.

### Logging note

GoldHEN's klog server **replays its buffer on connect**, so reconnecting after a
run still yields the whole run. That is how the triangle output above was
recovered after the receiver had gone stale.

And the receiver does go stale: the console suspended at 19:28:48
(`State Change: SUSPEND_ON_GOING`, `HW Indicator: Orange Blink`) and the socket
stayed ESTAB while delivering nothing. Check that the log is still growing, not
that the connection still exists.

---

## 2026-10-06 — THE PS4 PRO'S OTHER 18 COMPUTE UNITS WERE BEING MASKED BY THE DRIVER

`ac_orbis_drm.c` hardcoded `num_shader_engines = 2` and `device_id = 0x9920`,
both marked UNCITED. `cu_bitmap` is built from that, and RADV programs
`COMPUTE_STATIC_THREAD_MGMT` from `cu_bitmap` — so the driver was not merely
*mis-reporting* a Pro as a base PS4, it was configuring it as one.

Patched to pick Gladius from `sceKernelIsNeoMode()` (`patches/0001-*.patch`),
rebuilt Mesa, relinked, measured. Same console, same binary, same benchmark —
only the driver's idea of the topology changed.

### The scaling knee doubled

Per-wavefront rate while every wave still has a SIMD to itself: **6.125 GFLOP/s**.
`%lin` is the measured throughput against that straight line.

| waves | 18-CU config | %lin | 36-CU config | %lin |
|---|---|---|---|---|
| 8 | 48.9 | 100% | 49.0 | 100% |
| 16 | 97.5 | 99% | 97.5 | 99% |
| 32 | 195.8 | 100% | 194.0 | 99% |
| 64 | 384.3 | 98% | 384.7 | 98% |
| **96** | 464.6 | **79%** | 571.2 | **97%** |
| **128** | 623.8 | **80%** | 769.0 | **98%** |
| 192 | 689.4 | 59% | 908.5 | 77% |
| 256 | 739.1 | 47% | 1250.3 | 80% |

Before: linear to 64, broken by 96 → the machine has between 64 and 96 SIMDs.
**72** (18 CU × 4) is in that bracket; 144 is not.

After: linear all the way to 128, broken by 192 → between 128 and 192 SIMDs.
**144** (36 CU × 4) is in that bracket; 72 is nowhere near it.

The knee is the measurement that does not care about clock or ALU efficiency —
those scale the whole curve and leave the knee where it is.

### The plateau and the efficiency agree with it

```
plateau   950 -> 1830 GFLOP/s   (1.93x)

  18 CU @ 800 MHz: theoretical 1843, measured  950  -> 51.5% efficiency
  36 CU @ 800 MHz: theoretical 3686, measured 1830  -> 49.6% efficiency
```

Essentially **identical efficiency on twice the hardware**, which is what
doubling a compute array looks like and is not what a mislabelled constant looks
like. It also pins the GPU clock at ~800 MHz rather than the Pro's nominal 911 —
at 911 the efficiency would have to be 44%, and it would have had to *drop* on
the larger configuration for no reason.

### Attribution is clean

`/data/orbis-env.txt` was deleted before this run and the probe confirms it:

```
probe: sceKernelHasNeoMode()=1  sceKernelIsNeoMode()=1
probe: getenv(ORBIS_NUM_SE) = (null)
probe: getenv(ORBIS_CHIP)   = (null)
deviceID          0x9924   <- CHIP_GLADIUS
shaderEngineCount 4
=> compute units  36
```

So the four engines came from Neo detection inside the driver, not from a
leftover knob.

### The inconsistent raster_config does not break basic rasterisation

`ac_gpu_info.c`'s `CHIP_GLADIUS` entry pairs `0x2a00161a` (a TWO-engine high
half) with `0x0000002e` (Hawaii's FOUR-engine `SE_PAIR_MAP`), and its comment
calls the pair internally inconsistent and unresolvable without a Pro. The
triangle renders correctly on screen with it.

⚠ That is a weak test and should not be read as more. One full-screen triangle
barely exercises work distribution across shader engines, which is what that
register governs; upstream describes the failure mode as "quarter-of-the-screen
shaped". It rules out catastrophic breakage, not misbinning.

### Loose end, honestly unresolved

Setting `ORBIS_NUM_SE=4` through `/data/orbis-env.txt` earlier did **not** change
`shaderEngineCount`, even though the string is present in the bundled driver and
`ac_gpu_info.c:1249` assigns `max_se` from it with no clamp. The `getenv`
read-back that would have separated "our setenv never reached Mesa" from
"something downstream overrode it" was added to the probe but only ever ran with
the file absent, so it answered `(null)` and settled nothing. Moot for the fix —
the driver now decides for itself — but not explained.

---

## 2026-10-07 — stage 5 opens: the translator cross-compiles for the PS4 unmodified

Two console-free checks, both green.

### The upstream host suite passes here

`make test` in a fresh `prospero-win` checkout: **exit 0**, after installing
`gcc-mingw-w64-i686` and `gcc-mingw-w64-x86-64` (one test hard-asserts on them;
the rest of the Wine group skips cleanly without a host Wine). The line that
matters:

```
dynarec benchmark regression passed: 5 deterministic workloads; reg_alu matches native i386
```

So the translator is correct on this machine before anything PS4-specific
touches it. That is the baseline any later breakage gets measured against.

### And it builds for Orbis with no edits

`src/dbt/CMakeLists.txt` globs `prospero-win/src/*.c` through the bundle's
toolchain file: **24 translation units, 0 errors, 0 warnings under
`-Wall -Wextra`**, producing a 542 KB `libpw_dbt.a` for `elf64-x86-64`.

The undefined set is 39 symbols and contains nothing surprising:

```
memcpy memmove memset memchr bcmp      <string.h>
strchr strcmp strlen strncmp
mmap mprotect munmap                   the POSIX VM backend (pw_vm_posix.c)
orbis_sysconf                          orbis-compat interposing sysconf
__udivti3 __umodti3                    compiler-rt, 128-bit divide
pw_*                                   internal, resolved in-archive
```

No allocator, no formatter — which is upstream's deliberate choice, made so a
PS5 firmware's wrong libc symbols could not be inherited, and it is precisely
what makes the PS4 target cheap. `ARCHITECTURE.md` says so outright: *"the
cheapest way not to inherit that class of bug is not to import the symbol."*

⚠ **This is a build, not a run.** It says the headers and the ABI agree. Whether
translated code is correct on Jaguar is a hardware question; the host suite
answers the correctness half and the console has not seen any of this yet.

### What this does to the stage 5 estimate

The 13,519-LOC translator was the piece I could not cost without trying it. It
needed nothing. What remains is unchanged: ~10,700 LOC of platform layer
(`native/`, `wine/ps5/`, `wine/wineps5/`) to rewrite against PS4 APIs, and 81
Wine patches whose constants are *measured* rather than ported and must be
re-measured on Orbis.

---

## 2026-10-07 — the first prospero-win frame on a PlayStation 4

`Prospero Presenter` (GLDS10003) draws three colour bars through the
**unmodified** portable compositor and flips them: white bar on top, RED GREEN
BLUE left to right, 600 flips, steady.

```
present: 25165824 bytes mapped, 3 buffers of 8388608
present: opened with user 0xff
present: pixel format 0x80000000 A8R8G8B8 - byte0=B, matches the compositor (register rc 0)
present: compose -> 0, placed 1920x1080 at 0,0 scale 4
present: 600 frames, 600 flips
```

### The port is 170 lines, against ~350 on the PS5

| PS5 | PS4 |
|---|---|
| tiled intermediate + `pw_videoout_tile.h` index tables | `ORBIS_VIDEO_OUT_TILING_MODE_LINEAR` — gone |
| `pw_agc_ps5.c`: DMA the tiled frame into scanout, `sceAgcDcbSetFlip` | `sceVideoOutSubmitFlip` — gone |
| one copy per frame | none: the compositor draws straight into scanout |

`pw_present.h`'s target is already *"a writable linear BGRX surface"*, which is
exactly what a linear VideoOut buffer is. The PS5 needed the tiling pass and the
DMA because its scanout is tiled; the PS4's is not, so the whole intermediate
disappears.

### Two bugs, both found by running it, both measured rather than reasoned

**The pixel format was reversed.** With `A8B8G8R8_SRGB` (the only format the SDK
`#define`s) a red source column reached memory as `00 00 ff ff` — *correct*
B,G,R,A from the compositor — and the television showed it **blue**. So VideoOut
reads byte 0 as red: the order it wants is R,G,B,A, exactly as the name says
read MSB-first.

`pw_present.c`'s `store_opaque` writes B,G,R,A and is portable code we do not
change, so the fix is the format whose byte 0 is blue: **`A8R8G8B8`,
`0x80000000`**. Not in the SDK headers; named in `pw_videoout_ps4.c` with the
measurement beside it. `open()` tries it first and falls back to the defined
one, recording which was accepted — so a wrong guess would cost reversed colours
rather than a black screen. It was accepted first try.

⚠ My diagnostic *text* had the interpretation backwards on the first run. The
numbers were right and the conclusion from them was wrong by one inversion,
which is worth remembering: a dump is only as good as the sentence next to it.

**Two buffers flickered.** "Flip, then wait one vblank" is not enough — a CPU
compose of 1920x1080x4 does not reliably finish inside a frame, so the flip
lands late and the next compose starts writing the buffer still being scanned.
**A vblank is not the same event as a flip retiring.**

Three buffers now, and `acquire()` waits on `numFlipPending` from
`sceVideoOutGetFlipStatus` — the actual question — rather than on a vblank. The
wait lives in `acquire()` rather than `present()`, because blocking after a flip
stalls a caller that already has a free buffer to draw into.

### Two things the run corrected about my own expectations

- 480x270 at 4x is **exactly** 1920x1080, so there is no surround; the
  "surround pixel" check was reading the white bar. The composition was right
  and the expectation was wrong.
- `sceVideoOutOpen` with `0xFF` worked, so the signed-in-user fallback never
  fired. Kept anyway — it costs one call and removes a failure mode that has no
  other symptom.

### What this establishes for stage 5

The platform boundary is real now, not theoretical. The portable half of
prospero-win (`src/`, 13.5k LOC) builds for the PS4 unmodified and its output
reaches the screen through a PS4-native presenter. `native/pw_videoout_ps5.c`
and `pw_agc_ps5.c` are the first two of the ~10.7k LOC platform layer to be
replaced, and they came to 170 lines.

---

## 2026-10-07 — the DualShock 4 drives prospero-win's pad core

```
pad: open, user 0x173c98d4 handle 50922752
pad: pressed 0x00004000 held 0x00004000 L(121,119) R(125,122) L2=  0 R2=  0
pad: pressed 0x00000200 held 0x00000200 L(121,116) R(125,122) L2=  0 R2=198
pad: 3600 polls, 30587 connected, 732 empty, 0 errors, 1 generations
```

CROSS red, CIRCLE green, TRIANGLE yellow, SQUARE blue, L2/R2 dim — all four
face buttons and both analogue triggers, confirmed on screen.

### The core is upstream's, compiled unmodified

`native/pw_pad_ps5.c` reaches the platform only through `PwPadPs5Ops`, and
already guards its own PS5 filling of that vtable behind
`PW_PAD_PS5_HOST_TEST`. Defining it keeps the batching, connect/disconnect
generations, intercepted samples, edge detection and analogue centring, and
drops the eight PS5 forwards. `src/native/pw_pad_ps4.c` supplies those — 96
lines, of which seven functions are one line because **the PS4 exports the same
eight symbols**.

The ninth is the only real work. `OrbisPadData` and the DualSense sample are not
binary compatible: `connected` is `uint8_t` here and `int32_t` there, which
moves every field after it, and the accelerometer and gyro are swapped. So the
read lands in the PS4's struct and the seven fields `read_batch()` consumes are
copied by name. Everything else in `PwPadPs5Data` stays zeroed rather than
inventing a DualSense this console does not have. Button bits need no
translation — both consoles use Sony's layout.

### What the numbers prove

| reading | what it establishes |
|---|---|
| `pressed 0x4000` etc. | edge detection works through a vtable it was never written for |
| `L(121,117) R(125,121)` at rest | the struct translation landed on the right offsets — near 128 centre with a used pad's drift |
| `L2=50 R2=198` | the analogue path survives the copy |
| `0 errors, 1 generations` | it never once thought the controller had disconnected |
| 30587 samples / 3600 polls | ~8.5 per read: upstream's batching, running |

### Two bugs on the way, both mine, neither the PS4's

**A NULL key map silently disabled the pad.** `pw_pad_init` refuses one outright
(`if(!pad || !map || !count ...) return PW_ERR_PRECONDITION`), so
`pw_pad_ps5_open` returned before touching a single platform call. The failure
message then printed `pad_init_rc` and `user_initialize_rc` — both still zero
from the memset — which read exactly like the platform layer had succeeded.

⚠ **A misleading diagnostic is worse than none.** The fix was not only the map
but printing every step, so the failing one names itself instead of being
inferred from two zeroes.

**The surround kept being invisible** because 480x270 (4x) and 320x180 (6x) both
fill 1920x1080 *exactly*, leaving no border for the pad to tint — which looked
like the pad was broken when the pad was fine. 300x170 scales to 1800x1020 at
60,30 and leaves one. `surround px[0] = 20 18 18 ff` now matches the expected
value exactly, where before it was reading the white bar.

### Stage 5 platform layer so far

| upstream file | lines | replaced by | lines |
|---|---|---|---|
| `pw_videoout_ps5.c` + `pw_videoout_tile.h` + `pw_agc_ps5.c` | ~350 | `pw_videoout_ps4.c` | 170 |
| `pw_pad_ps5.c`'s platform block | ~15 | `pw_pad_ps4.c` | 96 |

The pad core itself, and the whole of `src/`, are upstream code compiled as-is.

---

## 2026-10-07 — audio, and the pattern that has held for three pieces

```
audio: port 536870919 open, 256 frames per grain at 48000 Hz, S16 stereo
audio: 187 grains played - a 440 Hz tone, about a second
```

187 x 256 = 47,872 frames at 48 kHz, 0.997 s, no failed output. Audible on the
television.

`src/native/pw_audio_ps4.c` is **62 lines**, all forwards. The constants are
identical on both consoles — `PORT_MAIN` 0, `FORMAT_S16_STEREO` 1, the `0xff`
system user, `0x8000` for 0 dB — so nothing translates. Worth checking rather
than assuming: upstream names them privately instead of importing them, and a
wrong format constant produces **silence rather than an error**, which is the
hardest kind of wrong to notice.

⚠ The tone plays *before* the video loop, not interleaved. `sceAudioOutOutput`
blocks until the port takes the grain, and 256 frames at 48 kHz is 5.33 ms
against a 16.6 ms frame: one grain per frame starves the port, three couples the
render loop to the audio clock. Wine's driver hands down one grain at a time and
clocks itself, so the real integration will not have this shape — but a test
whose job is "does the port open and play" should not inherit a timing problem
it is not testing.

## The platform layer so far

| upstream | lines | this port | lines | upstream code reused |
|---|---|---|---|---|
| `pw_videoout_ps5.c` + `pw_videoout_tile.h` + `pw_agc_ps5.c` | ~350 | `pw_videoout_ps4.c` | 170 | the compositor, unmodified |
| `pw_pad_ps5.c` platform block | ~15 | `pw_pad_ps4.c` | 96 | the whole pad core, unmodified |
| `pw_audio_ps5.c` platform block | ~20 | `pw_audio_ps4.c` | 62 | `pw_audio_ps5_open_port`, unmodified |
| `src/` — the i386 translator | — | — | 0 | 13,519 LOC, unmodified |

**The pattern, three for three:** upstream separated portable code from platform
code with a vtable and a `*_HOST_TEST` guard, built for host testing, and that
seam serves a different console just as well. Two of the three ports are forwards
with one translating function between them; the presenter is larger only because
the PS4 needs *less* than the PS5 and the difference had to be written down.

⚠ **This does not generalise to what is left.** `wine/ps5/` is a PRX loader, a
heap, threads and a working-directory shim — none of it sits behind a vtable,
and the 81 Wine patches carry constants that were *measured* on PS5 firmware
rather than ported. The easy three were easy because somebody designed them that
way.

---

## 2026-10-07 — the module loader ports too, and the PS5 offsets are right on this console

```
dl: sceKernelGetModuleInfo(0) -> 0
dl: pw_prx_parse_module_info -> 0, name 'eboot.bin', 3 segment(s)
dl:   seg 0  0x400000  589824 bytes  prot 0x5
dl:   seg 1  0x49c000  688128 bytes  prot 0x3
dl:   seg 2  0x490000   49152 bytes  prot 0x1
```

I expected `wine/ps5/` to break the pattern. It mostly does not:

- `pw_wine_prx.c` uses **no Sony APIs at all** — pure PRXDESC1 parsing, which
  upstream calls host-testable and means it.
- `pw_wine_dl.c` reaches the kernel only through `PwWineDlOps`: *"The kernel
  calls are injected so the logic is host-testable."*
- All three calls exist on the PS4 — `sceKernelLoadStartModule`,
  `sceKernelGetModuleInfo`, `sceKernelStopUnloadModule` — and `sceKernelDlsym`
  besides.

`src/native/pw_wine_dl_ps4.c` is **73 lines of forwards**. No guard macro was
even needed: upstream keeps the Sony calls in a separate `*_libc.c` companion,
which this build simply does not compile.

### The layout claim, and why it was worth testing rather than computing

`pw_prx_parse_module_info()` hardcodes PS5 offsets. The PS4 SDK's
`OrbisKernelModuleInfo` computes to the same ones:

| field | computed from the PS4 header | parser expects |
|---|---|---|
| `name` | 0x0008 | 0x0008 |
| `segmentInfo[4]` | 0x0108 | 0x0108 |
| `segmentCount` | 0x0148 | 0x0148 |
| total | 0x0160 | 0x0160 |

But that is a claim about a **header**, and the kernel is the authority — so the
test asks the kernel about module 0 and hands the raw bytes to upstream's
parser. The result is not merely "no error":

```
text   0x400000 + 0x90000 = 0x490000   where rodata begins
rodata 0x490000 + 0x0C000 = 0x49C000   where data begins
```

**The segments tile exactly**, in the right order, with the right protections
(0x5 R|X, 0x1 R, 0x3 R|W), and 0x400000 matches the load address from this
morning's `PRX_SCE_MODULE_LOAD_ERROR` dump. Wrong offsets do not produce a
contiguous correctly-permissioned tiling by accident.

⚠ A wrong offset here would not have errored. It would have read segment
addresses from the wrong place, and the descriptor scan would have failed later
looking like a missing PRXDESC1 — several layers from the cause.

### Four for four

| upstream | lines | this port | lines | upstream reused |
|---|---|---|---|---|
| videoout + tiling + AGC | ~350 | `pw_videoout_ps4.c` | 170 | the compositor |
| pad platform block | ~15 | `pw_pad_ps4.c` | 96 | the whole pad core |
| audio platform block | ~20 | `pw_audio_ps4.c` | 62 | `pw_audio_ps5_open_port` |
| dl platform block (`*_libc.c`) | ~70 | `pw_wine_dl_ps4.c` | 73 | dlopen/dlsym/dladdr **and** all PRXDESC1 parsing |

⚠ **Still not generalising to everything.** This proves the *loader* ports. It
does not load a Wine PRX, because none is built yet — that needs
`tools/build_wine_ps5.sh`, the 81-patch series, and a working-directory, heap
and thread shim none of which sits behind a vtable. What it does establish is
that when a Wine PRX exists, the machinery to find and resolve it is in place
and its module-info reading is correct on this hardware.

---

## 2026-10-07 — direct memory, and five for five

```
dmem: add_region(0x40000000, 16777216) -> 0
dmem: commit 262144 bytes RW -> 0, backed 262144
dmem: wrote and verified 65536 words, 0 mismatched
dmem: fresh page reads 0x00000000 (expect 0)
dmem: backed 278528 peak 278528, 2 allocs 2 maps 0 protects 0 failures, 1 runs
dmem: replace(..,0) -> 0, backed now 0, 1 releases
```

The whole lifecycle: reserve an address region, commit pages into it, write a
pattern through those addresses and read it back, confirm a freshly backed page
arrives zeroed, then give it all back with nothing left behind.

⚠ **The read-back is the test, not the return codes.** `reserve`, `allocate` and
`map` all returning 0 says only that the kernel accepted the calls. A map at the
wrong physical offset returns success and hands back somebody else's page. 65,536
words written and verified through the mapped addresses is what proves the
memory landed where it was asked for.

### Two PS4-specific traps

**`sceKernelAllocateMainDirectMemory` is unusable here.** The OpenOrbis header
declares its last parameter `off_t` **by value** where it must be `off_t *` — the
physical offset cannot come back. A header bug, and one that would have produced
a garbage offset and a map landing nowhere. `sceKernelAllocateDirectMemory` has
the correct out-pointer and an explicit `[start, end)` search range, which the
PS5's "main" variant does not take.

**The memory type is not the scanout's.** `pw_videoout_ps4.c` uses WC_GARLIC (3)
because the compositor only ever writes a surface the display only ever reads.
Wine's heap and stack are read far more than written, so this uses WB_ONION (0),
cached and CPU-coherent. The wrong one here works and is slow in a way nothing
reports.

⚠ And a correction to the presenter while passing: its comment called type 3
*WB_ONION*. It is WC_GARLIC. Right value, backwards reason — left as a visible
note rather than quietly fixed, because a constant that works for a reason
nobody wrote down is a constant somebody later "fixes".

### A misread of the API that looked like a leak

The first run called `pw_wine_dmem_protect(range, 0)` to free, and got `rc 0`
with `backed_bytes` unchanged and `releases` still 0 — which reads exactly like
a leak in this port. It is not:

- `protect(range, 0)` declines to **back** reserved pages; backed pages stay.
- `replace(range, 0)` is the one whose header says *"protection 0 leaves it
  reserved"*, and which releases the direct memory behind it.

Worth recording because the failure mode is a leak that **reports success**.

### Five for five

| upstream | lines | this port | lines | upstream reused |
|---|---|---|---|---|
| videoout + tiling + AGC | ~350 | `pw_videoout_ps4.c` | 170 | the compositor |
| pad platform block | ~15 | `pw_pad_ps4.c` | 96 | the whole pad core |
| audio platform block | ~20 | `pw_audio_ps4.c` | 62 | `pw_audio_ps5_open_port` |
| dl platform block | ~70 | `pw_wine_dl_ps4.c` | 73 | dlopen/dlsym/dladdr, PRXDESC1 parsing |
| dmem platform block | ~130 | `pw_wine_dmem_ps4.c` | 121 | the whole region allocator |

**522 lines of PS4 platform code** against `src/`'s 13,519 LOC translator plus
the pad core, the compositor, the module loader and the region allocator, all
compiled unmodified.

⚠ The pattern is upstream's doing, not this port's cleverness: every one of
these five sits behind a vtable or a `*_HOST_TEST` guard that somebody put there
on purpose. What is left — the heap, threads, the working-directory shim, and
the 81 Wine patches whose constants were *measured* on PS5 firmware — does not.

---

## 2026-10-07 — the heap's reason for existing does not apply to the PS4

`pw_wine_heap.c` needed **no porting at all** — 265 lines of pthread, string.h
and sys/mman.h, no Sony calls anywhere, compiles for the PS4 as-is. Its
`*_libc.c` companion is deliberately not built: that one interposes malloc/free
globally, and the heap should be exercised through its own API before every
allocation in the process depends on it.

But it exists for a **measured PS5 reason**, stated in its own header: *"Heap for
Wine's Unix side on the PS5, where the title's libc malloc stops near 13 MiB."*

That is not true here.

```
heap: libc malloc reached 1024 MiB in 1048576-byte blocks (hit the test's ceiling)
heap: pw_wine_heap reached 433 MiB before refusing
heap: live 454033408 mapped 461127680 peak 461127680, 433 allocs 1 failures 433 large
heap: foreign free counted 1 times (expect 1), live now 0
heap: memalign(4096,100) -> 0x229c01000 aligned=1 usable=100
```

**PS5 libc malloc: ~13 MiB. PS4 libc malloc: over 1 GiB, never refused.** At
least 80x, and the real ceiling is unknown because the test stopped first.

And prospero's heap is the *more* constrained of the two on this console: 433
MiB, because it maps each large block separately and meets a mapping limit libc
does not.

⚠ **The first run's numbers were right and I distrusted them for a good reason.**
It touched one byte per 16 KiB, so if flexible memory paged at 4 KiB only a
quarter of each block would have been committed and libc's figure inflated by
exactly that. Re-run committing every 4 KiB: **both numbers identical**, 433 MiB
and the ceiling again. The hypothesis was worth testing and was wrong.

That 433 MiB repeating exactly across two runs is itself the signal — a pool
limit, not noise.

### What it means for the port

On the PS4, Wine's Unix side can likely use libc malloc directly and skip this
heap entirely: simpler, and more than twice the headroom. The heap becomes
insurance rather than necessity.

⚠ **Not yet a decision.** What is measured is *large-block* behaviour, 1 MiB at
a time. The PS5 cap may bite differently on the small-block path (the heap
carves power-of-two classes out of 1 MiB mappings for anything under 64 KiB),
and Wine allocates small far more often than large. Worth measuring before
anything is removed.

The rest of the heap checks out regardless: foreign frees counted and ignored
exactly once, `memalign(4096,100)` correctly aligned with usable size 100, live
bytes back to 0 after every free.

### Six for six

| upstream | lines | this port | lines |
|---|---|---|---|
| videoout + tiling + AGC | ~350 | `pw_videoout_ps4.c` | 170 |
| pad platform block | ~15 | `pw_pad_ps4.c` | 96 |
| audio platform block | ~20 | `pw_audio_ps4.c` | 62 |
| dl platform block | ~70 | `pw_wine_dl_ps4.c` | 73 |
| dmem platform block | ~130 | `pw_wine_dmem_ps4.c` | 121 |
| **heap** | — | **nothing** | **0** |

---

## 2026-10-07 — threads, and a scheduling fact no header states

`pw_wine_threads.c` needed no porting: 62 lines of pthread, errno, sched,
signal and unistd. Its companion did — `pw_wine_threads_libc.c` includes
`<sys/thr.h>` and **the PS4 SDK has no such header**. Replaced in eight lines.

```
threads: register(0x7357) -> 0
threads: kill(unregistered) -> -1 errno 3 (ESRCH)
threads: kill(registered) -> 0, handler ran = 1
threads: kill after unregister -> -1
```

The signal reached the specific registered thread, an unregistered id was
refused rather than guessed at, and unregistering took effect — which matters
because the kernel reuses thread ids, and a stale entry would deliver Wine's
suspend signal to the wrong thread.

### ⚠ thr_self is not a function on the PS4

The SDK knows it only as syscall number 432 (`SYS_thr_self`); libkernel exports
no `thr_self`, `thr_kill` or `thr_kill2`. Which is exactly why this registry
exists — wineserver signals with `thr_kill2(pid, lwpid, sig)`, no console
provides it, so ntdll maps kernel ids onto `pthread_t` and `thr_kill2` becomes a
lookup plus `pthread_kill`.

**Open, deliberately not guessed at:** which `long` ntdll will register as the id
here. musl's `syscall()` is on the link line but uses Linux conventions, and
whether `SYS_thr_self` survives that on a FreeBSD-derived kernel is untested. It
does not matter yet — the registry is a map and any unique key works, which is
why the test uses synthetic ids — but ntdll and wineserver must agree once both
are real.

### Orbis admits only the realtime policies, and the range is 256..767

`pthread_setschedparam(SCHED_OTHER, 0)` returned **EINVAL**. Probed on hardware
rather than reasoned about:

| policy | `sched_get_priority_min` | `max` | `pthread_setschedparam` |
|---|---|---|---|
| 0 — musl's `SCHED_OTHER` | -1 | -1 | **22 EINVAL** |
| 1 — `SCHED_FIFO` | 256 | 767 | **0** |
| 2 — musl's `SCHED_RR`, FreeBSD's `SCHED_OTHER` | -1 | -1 | **22 EINVAL** |
| 3 — FreeBSD's `SCHED_RR` | 256 | 767 | **0** |

⚠ **My hypothesis was half right, and the half that was wrong is the
interesting half.** The SDK's `sched.h` is musl's and carries Linux policy
numbers (`OTHER 0, FIFO 1, RR 2`) while this kernel is FreeBSD-derived
(`FIFO 1, OTHER 2, RR 3`) — so I expected policy 2 to be accepted as FreeBSD's
`SCHED_OTHER`. It is not. **Orbis admits only 1 and 3, the two realtime
policies, and rejects `SCHED_OTHER` under either numbering.** That is a console
deciding something, not a header disagreeing.

Consequences for anything using this SDK:

- `SCHED_OTHER` from `sched.h` is **never** valid. Code that passes it gets
  EINVAL, and the header gives no hint.
- `SCHED_RR` from `sched.h` is **2**, which is also rejected. The accepted RR is
  **3**.
- `SCHED_FIFO` is the one value where musl and this kernel agree.
- The priority range is **256..767**, stated in no SDK header. `sched_get_
  priority_min/max` is the only source, and it returns -1 for a policy the
  kernel does not take — which is a usable probe.

This is the class of defect `orbis-compat` exists to correct, and it is
uncorrected. Worth sending upstream with the Gladius measurement.

### Seven for seven

| upstream | lines | this port | lines |
|---|---|---|---|
| videoout + tiling + AGC | ~350 | `pw_videoout_ps4.c` | 170 |
| pad platform block | ~15 | `pw_pad_ps4.c` | 96 |
| audio platform block | ~20 | `pw_audio_ps4.c` | 62 |
| dl platform block | ~70 | `pw_wine_dl_ps4.c` | 73 |
| dmem platform block | ~130 | `pw_wine_dmem_ps4.c` | 121 |
| heap | — | nothing | 0 |
| threads companion | ~7 | `pw_pthread_stack_ps4.c` | 8 |

---

## 2026-10-07 — the working directory, and a lesson about instrumentation

Both halves of `pw_wine_cwd` are pure POSIX, so neither needed porting. What
they needed was the **28 `--wrap` flags**: the libc half defines `__wrap_open`
and calls `__real_open`, and lld only creates that pairing when told to, per
symbol. A build missing them links cleanly, runs, and resolves no relative path
at all — the failure is **silence**.

### The kernel, measured through `__real_*`

```
__real_getcwd          -> (null) errno 78   ENOSYS
__real_chdir("/data")  -> -1     errno 1    EPERM
__real_open(relative)  -> -1     errno 2    ENOENT
__real_symlink         -> -1     errno 78   ENOSYS
```

| | PS5 (upstream's measurement) | PS4 (this console) |
|---|---|---|
| `chdir` | EPERM for every path | **EPERM** — same |
| `getcwd` | **faults** | ENOSYS |
| `symlink` | **kills the process** | ENOSYS |

So the problem is real here and the shim is needed — but upstream's two
*dangers* are not. A stray `symlink` merely fails; it does not take the title
down. That makes this code considerably safer to develop against than its own
header warns.

### The shim, driven

```
pw_cwd_set(/data) -> 0, pw_cwd_get -> '/data'
open("pkg") relative   -> 15        resolved against /data
set("..")              -> -1 EINVAL correctly refused
set(/data/pkg/..)      -> '/data'   folded lexically
stat("pkg") relative   -> 0, dir=1  stat is wrapped too, not just open
```

That last line matters: Wine touches all 28 of these, and one unwrapped call is
a path silently resolving against nothing.

### ⚠ Twice in this piece my instrumentation was the thing at fault

**A run reported that `chdir` and `symlink` "work, unlike the PS5".** They do
not. Once the wraps are on the link line those names resolve to the shim's own
logical implementations — the test was measuring this port and calling it the
console. Fixed by probing `__real_*` and the wrapped names side by side in one
run, so neither answer can be mistaken for the other.

**A run reported that lexical folding had failed.** It had not: `pw_cwd_set`
documents `EINVAL` for a relative path, and `".."` was correctly refused.
Folding applies to `".."` *inside* an absolute path. The test was misusing the
API.

Both would have entered this record as console facts. A test that reports
confidently and wrongly is worse than no test, and the only thing that caught
either was going back over numbers that already looked like an answer.

### Eight for eight — the platform layer is complete

| upstream | lines | this port | lines |
|---|---|---|---|
| videoout + tiling + AGC | ~350 | `pw_videoout_ps4.c` | 170 |
| pad platform block | ~15 | `pw_pad_ps4.c` | 96 |
| audio platform block | ~20 | `pw_audio_ps4.c` | 62 |
| dl platform block | ~70 | `pw_wine_dl_ps4.c` | 73 |
| dmem platform block | ~130 | `pw_wine_dmem_ps4.c` | 121 |
| heap | — | nothing | 0 |
| threads companion | ~7 | `pw_pthread_stack_ps4.c` | 8 |
| cwd | — | nothing (28 `--wrap` flags) | 0 |

**530 lines of PS4 platform code.** Underneath it, compiled unmodified: the
13,519-LOC i386 translator, the compositor, the pad core, the audio port
policy, dlopen/dlsym/dladdr with PRXDESC1 parsing, the direct-memory region
allocator, the heap, the thread registry, and the working-directory shim with
its virtual symlink table.

What is left is not a vtable: `tools/build_wine_ps5.sh` and the 81-patch series,
whose constants were *measured* on PS5 firmware rather than ported.

---

## 2026-10-07 — Wine's PE runtime builds (step 1 of 3)

```
wine runtime manifest check passed: 3 modules, 76 data file(s),
  wine=490f6d5dcbb2, digest=429f37b6477f264beec5b719a0d9d857412bf20a39bca20bef515faa115a35e4
```

**Wine 11.17**, the pinned revision, configured `--enable-archs=i386,x86_64
--disable-tests`. Output: `ntdll.dll`, `kernelbase.dll`, `kernel32.dll`, all
`PE32 executable for WINE (DLL), Intel i386`, 11 MB, with 11 MB of NLS data
beside them. The manifest's reproducibility check passed, so a later rebuild of
the same commit gives byte-identical files.

Needed one host package the script does not name: **FreeType development
headers**. Configure's other misses (EGL, X11, GL, v4l2) are warnings; FreeType
is fatal and it is the only one.

### The Wine build is three pieces, not one

Reading `tools/build_wine_ps5.sh` properly changed the estimate:

| piece | needs | state |
|---|---|---|
| host PE runtime | mingw, bison, flex, FreeType | **done** |
| the 81-patch series + ELF link | OpenOrbis SDK | next |
| **PRX link** | `ps5-native-tool`, foundation `30597512…`, branch `exp/prx-module` | **the obstacle** |

⚠ **The PRX link is the part that could stall this.** It converts and signs
Wine's modules into something the console loads, and it runs through PS5 tooling
from a separate repository. Without it the script *skips the PRX link and says
why* — Wine would build as ELF and never become loadable.

The PS4 substitute is OpenOrbis's own `.sprx` path, which demonstrably works:
`libc.prx` and `libSceFios2.prx` in our own packages are exactly that format. So
it is substitutable rather than impossible — but it is a port, not a flag.

⚠ **Vulkan, by contrast, is already in hand.** The script's `--radv DIR` takes a
Mesa RADV checkout instead of Sony's `ps5vk`, and `mesa-build/` holds a working
Gladius-patched one. One of the harder-looking dependencies was solved days
before it was needed.

---

## 2026-10-07 — ⚠ checking what is already adjudicated beats re-measuring it

Zak's correction, and it was right: *"The PS4 and PS5 seem similar, so lots learned
from the PS4 was brought to the PS5. In some cases you are making assumptions on
things that may already be adjudicated."*

The PS4 came **first**. Upstream's PS5 measurements are often rediscoveries of PS4
facts that a ten-year-old homebrew scene already settled, and `orbis-compat`
exists precisely to record them. I had been treating every PS5 constant as needing
fresh measurement here. That is backwards, and it cost a crashed title.

⚠ **A bad probe kills the title, not the console** (Zak, 2026-10-07, correcting
my note above -- the signal probe took the app down, the system stayed up).
GoldHEN survives, FTP survives, and a reinstall-and-rerun is a couple of
minutes. So on-hardware probing is CHEAP and is usually the fastest way to
settle a constant. Do not reason around a question that one throwaway title
would answer. (The thing that genuinely does kill GoldHEN is an FTP login --
see `scripts/ftp-put.py`.)

### Patch 0510 was already settled — no measurement needed

```
orbis_jit.h:54   /// The unit sceKernelMprotect and sceKernelMapDirectMemory work in.
                 /// 16 KiB, not the 4096 a Linux…
orbis_jit.h:58   #define ORBIS_JIT_GRANULE 0x4000u
orbis_mmap.h:77  // rounded up to a 16 KiB page (`addq $0x400f; andq $-0x4000`, so
                 // PAGE_SIZE is 16 KiB on…
```

**16 KiB, same as the PS5**, and derived by disassembling the kernel's own
rounding — better evidence than the probe I was about to run. Patch 0510 applies
unchanged.

### Patch 0501 is genuinely open, and the header proves why

The SDK's `bits/signal.h` declares a **Linux** `ucontext_t`:

```c
typedef struct __ucontext {
    unsigned long uc_flags;        /* FreeBSD puts uc_sigmask FIRST */
    struct __ucontext *uc_link;
    stack_t uc_stack;
    mcontext_t uc_mcontext;
    ...
#define SA_SIGINFO 4               /* FreeBSD: 0x0040 */
#define SA_ONSTACK 0x08000000      /* FreeBSD: 0x0001 */
```

FreeBSD's is `{ uc_sigmask, uc_mcontext, uc_link, uc_stack, uc_flags }`.
`orbis-compat` corrects the `SA_*` flags and `stack_t`, but **not** `ucontext_t`
— so patches 0500 and 0501 are needed here too. What does not transfer is the
PS5's numbers; what does transfer is that FreeBSD 9's layout is **public source**,
so these offsets can be derived and then confirmed rather than discovered by
faulting.

### ⚠ The crash was mine, and reading first would have prevented it

The probe scanned 2048 bytes from `uc`. FreeBSD's `ucontext_t` is around 800;
upstream's +896 fits a larger PS5 frame, not this one. So it ran off the end into
unmapped memory **inside a signal handler**, which is unrecoverable.

`orbis-compat` warns about exactly this area in its own words — *"this port's own
crash reporter has been dying of it since the day it was written"* — and I wrote
a novel faulting probe anyway.

The same file also documents, measured on hardware, that musl's `SA_SIGINFO` of 4
means `SA_RESETHAND` to this kernel, so a handler asking for siginfo is installed
**one-shot and without siginfo**, and arrives with FreeBSD's original
`void(*)(int, int, struct sigcontext *)` signature.

### The rule this earns

Before measuring anything upstream measured on a PS5: check `orbis-compat`'s
corrections, the OpenOrbis headers, and FreeBSD 9's public layout. The PS4 is the
older console and the better documented one. Measure only what none of them
answer — and bound the measurement to a structure size that is known first.

---

## 2026-10-07 — Wine compiles for a PlayStation 4, and the 307 errors are all missing headers

All **83 patches apply cleanly** to pinned Wine 11.17 — zero rejects. Configure
**passes**: Wine accepts the PS4 compiler and takes its FreeBSD paths, which is
the premise the whole port rests on.

### The shim, and three obstacles between CMake and a compiler driver

`tools/build_wine_ps5.sh` requires `$sdk/bin/prospero-clang` by that exact name.
Rather than fork a 600-line script, `build/ps4-wine-sdk/bin/prospero-clang`
presents the OpenOrbis toolchain under it with `ps4-openorbis.cmake`'s own flags.
Getting it to *link* took three goes:

1. **Compile flags are not enough** — configure's first act is "can the compiler
   create executables", which needs the whole link rule: `-nostdlib`, the
   overlay's linker script (not the SDK's `link.x`), and `crt1.o` **last**.
2. **`-fuse-ld=lld` is rejected**: *"unsupported option '-fuse-ld' for target
   'x86_64-scei-ps4'"*. The PS4 driver picks its own linker.
3. **It then wants `orbis-ld`**, Sony's linker name. OpenOrbis ships `ld.lld`, so
   `bin/orbis-ld` is a symlink and the shim prepends its own directory to `PATH`.

CMake sidesteps all three by driving the linker directly instead of through the
compiler driver — which is why the triangle built fine while this did not.

### `-D__PROSPERO__` on purpose, as mechanical triage

Sony sets `__PROSPERO__` for the PS5 and `__ORBIS__` for the PS4: siblings
meaning "Sony console, FreeBSD derived, not Linux". 35 patches gate on it.
Defining it turns all 35 arms on at once so the genuinely PS5-only ones fail and
**name themselves** — faster and more honest than reading 35 patches and guessing.

### The result: zero patch failures

307 errors, and **not one of them is in a patched arm.** Every single one is a
FreeBSD header the OpenOrbis SDK omits:

| failing file | errors | wants |
|---|---|---|
| `ntdll/unix/cdrom.c` | 133 | `sys/cdio.h` — `CDIOC*`, `struct ioc_toc_header`, … |
| `ntdll/unix/file.c` | 63 | `sys/mount.h` — `MNT_RDONLY` |
| `ntdll/unix/system.c` | 28 | `sys/time.h` — `struct clockinfo` |
| `server/sock.c` | 19 | `net/bpf.h` — `BPF_LD`, `struct sock_filter` |
| `ntdll/unix/socket.c` | 7 | `sys/sockio.h` — `SIOCATMARK` |
| `ntdll/unix/signal_x86_64.c` | 7 | `machine/sysarch.h` — `sysarch` |
| `ntdll/unix/server.c`, `env.c` | 14 | `sys/ttycom.h` — `TIOCGWINSZ` |

This is `orbis-compat` §2.2's category exactly — *"Headers the SDK omits although
the platform has them"* — and the overlay already supplies eight of that kind
(`cpuset.h`, `dirent.h`, `endian.h`, `ioccom.h`, `ioctl.h`, `param.h`,
`sysctl.h`, `umtx.h`). Wine needs about six more.

⚠ Note `signal_x86_64.c` fails on **`sysarch`**, not on anything patches 0500 or
0501 touch. I had predicted those two would break first, on the Linux-vs-FreeBSD
`ucontext_t` mismatch. They did not. The prediction was reasonable and wrong, and
the compiler settled it in one run.

⚠ **And a correction to my own first reading.** A grep for errors mentioning
"ps5" returned 299 of 307 — which looked like near-total patch failure. It was
matching the *directory name* `.deps/wine-ps5/` in every path. Matching the error
MESSAGE instead gives **zero**. The same class of mistake as the cwd probe:
instrumentation reporting confidently about itself.

### What this leaves

The patch series is viable on the PS4. What stands between here and `ntdll.so`
is a set of missing FreeBSD headers — bounded, mechanical, and the exact kind of
thing `orbis-compat` exists to carry. After that, the PRX link remains the one
genuinely unknown piece.

---

## 2026-10-07 — 307 → 106 errors on headers alone, and the real blocker surfaces

`src/freebsd-compat/` is 14 headers, ~500 lines: the FreeBSD 9 declarations the
OpenOrbis SDK omits although the platform has them — `orbis-compat` §2.2's
category, which the overlay already carries eight of.

| pass | errors | what changed |
|---|---|---|
| 1 | 307 | none |
| 2 | 251 | cdio, sockio, ttycom, sysarch, bpf, mount, time, filio, conf |
| 3 | **106** | cdio completed; `cdrom.c`'s 132 errors gone entirely |
| 4 | 261 | trap.h and thr.h added — and the count **rose** |

### ⚠ Four traps, each of which made a header look ignored

**An empty header is worse than no header.** `dev/acpica/acpiio.h` was written
deliberately empty so Wine would take its absent-hardware branch. Configure
tests header *existence*, set `HAVE_DEV_ACPICA_ACPIIO_H`, and Wine then included
it and demanded `ACPI_BATT_STAT_CHARGING` from an empty file. Deleted.

**`<sys/ioctl.h>` must chain.** `TIOCGWINSZ`, `SIOCATMARK` and `FIODTYPE` stayed
undeclared long after `ttycom.h`, `filio.h` and `sockio.h` existed, because Wine
includes `<sys/ioctl.h>` and expects them *through* it as FreeBSD's does. The
SDK's does not chain. It looked exactly like the headers were off the path.

**`__BEGIN_DECLS` does not exist in this SDK**, and `fsid_t` is not reachable
from anything `sys/mount.h` includes. Both were compile errors *inside
configure's test*, so `HAVE_SYS_MOUNT_H` came back "no" while the header sat
right there.

**And an unguarded `struct winsize`** in `ttycom.h` made the `sys/mount.h` test
fail with "redefinition of 'winsize'" — a failure reported against the wrong
header entirely.

### The count rising was the useful result

Adding `machine/trap.h` and `sys/thr.h` took configure onto Wine's **FreeBSD**
signal path, and `signal_x86_64.c` went from 7 errors to 131:

```
no member named 'mc_rsp' in 'mcontext_t'
no member named 'mc_rip' in 'mcontext_t'
no member named 'mc_rdi' in 'mcontext_t'   … and the rest of the register file
```

That is the Linux-vs-FreeBSD `ucontext_t` mismatch, and it is **patch 0500's
exact subject**. The SDK declares a Linux `mcontext_t`; Wine's FreeBSD arm wants
FreeBSD's.

⚠ I predicted 0500/0501 would break first, the first build said otherwise, and I
recorded the prediction as wrong. It was **premature, not wrong** — the first
build could not reach that code. Both readings were honest; only the second had
enough headers to be informative.

### Also settled: where a PS4 thread id comes from

`pthread_getthreadid_np` is exported by libkernel, verified against the stub
library. That closes the question flagged during the thread-registry work —
`thr_self` is not exported and musl's `syscall()` uses Linux conventions, but
this is a plain function call needing neither.

### What remains

A FreeBSD `mcontext_t` for the signal path, the BPF guard in `server/sock.c`,
and `getmntinfo`. Then the PRX link, still the one genuinely unknown piece.

---

## 2026-10-07 — ⭐ Wine's Unix side builds for a PlayStation 4

```
dlls/ntdll/ntdll.so         built=True  unresolved=none    3.8M
dlls/win32u/win32u.so       built=True  unresolved=none    8.8M
server/wineserver           built=True  unresolved=none    4.3M
dlls/winevulkan/winevulkan.so  built=True  malloc=imports
dlls/opengl32/opengl32.so      built=True  malloc=imports
dlls/ws2_32/ws2_32.so          built=True  malloc=defines
dlls/crypt32/crypt32.so        built=True  malloc=defines
dlls/dwrite/dwrite.so          built=True  malloc=defines
```

**Eight targets, 28 MB, zero errors.** Wine 11.17, 83 patches, built against the
OpenOrbis toolchain for `x86_64-scei-ps4`.

Error trajectory: **307 → 251 → 106 → 142 → 44 → 23 → 7 → 0.**

### What it took

| | |
|---|---|
| `src/freebsd-compat/` | 15 headers, ~550 lines of FreeBSD 9 declarations the SDK omits |
| `src/wine-patches-ps4/` | upstream's 83, two given PS4 arms |
| `build/ps4-wine-sdk/` | a shim presenting OpenOrbis as `prospero-clang` |

### The shim, and three things CMake hides

The build script requires `$sdk/bin/prospero-clang` by that name. The shim wraps
host clang with `ps4-openorbis.cmake`'s flags, and linking took four discoveries:

1. **Compile flags are not enough** — configure's first act is "can the compiler
   create executables".
2. **`-fuse-ld=lld` is rejected** for `x86_64-scei-ps4`; the driver picks its own.
3. **It wants `orbis-ld`**, Sony's linker name — `bin/orbis-ld` symlinks `ld.lld`.
4. **`-pie` and `crt1.o` are for executables only.** `orbis-ld` refuses
   "-shared and -pie may not be used together", and `crt1.o` carries `_start`
   and the process parameter block, which a `.so` must not define.

CMake sidesteps all four by driving the linker directly rather than through the
compiler driver, which is why the triangle built while this did not.

### ⚠ Five ways I mangled a patch before finding the method

Each failed differently and none said "your patch is incomplete":

1. Hand-written hunk context — corrupt at line 51
2. Edited the text, breaking the hunk's line counts
3. Targeted a line a *later* patch introduces (the `C_ASSERT` comes from 0883)
4. Header extracted with the wrong `sed` range — patch began at `Subject:`
5. **`git diff` omits untracked files**, silently dropping the two new sources
   0883 adds. That one surfaced three layers away: the patch applied, configure
   completed, and `config.status` failed generating Makefiles.

The method that works every time: apply everything before it, apply the patch,
edit the **source**, `git add -A`, then `git diff --cached` beneath the original
header up to the first `diff --git`.

### ⚠ And the ACPI header, wrong in both directions

Written **empty** so Wine would take its absent-hardware branch: configure tests
header *existence*, set `HAVE_DEV_ACPICA_ACPIIO_H`, and Wine demanded
`ACPI_BATT_STAT_CHARGING` from an empty file. **Deleted**: `fatal error: file
not found`, because `system.c` includes it unconditionally under
`#elif defined(__FreeBSD__)`. There is no branch to fall into — on a FreeBSD
target Wine always compiles its ACPI path. It needs the header *and* two
constants, and the PS4's absent `/dev/acpi` makes the ioctl fail at runtime,
which Wine already handles.

### ⚠⚠ COMPILING IS NOT WORKING

The mcontext offset is **a guess**: FreeBSD's +16, where the PS5 measured +64.
Sony has moved it at least once.

- The `C_ASSERT` pins `mc_cs` at 168 in our struct, which independently matches
  the PS5's `+64 + 168 = 232` arithmetic — corroboration of the *layout*, not of
  the offset.
- `mc_len` carries `sizeof(mcontext_t) == 800`, readable at the chosen offset as
  a cheap runtime check.
- Patch 0883's signal-entry **assembly depends on the same number**.

Nothing here has run on the console. A wrong offset means every exception reads
the wrong registers.

## Wine PRX modules build for PS4 (2026-10-07)

All eight Unix-side modules now convert to loadable PRX:
ntdll, win32u, wineserver, winevulkan, opengl32, ws2_32, crypt32, dwrite.

### The export bug that would have wasted a hardware session

`-fvisibility-from-dllstorageclass` is **on by default for the
`x86_64-scei-ps4` target** (with `-fvisibility-nodllstorageclass=hidden`).
It makes `__declspec(dllexport)` the only thing that can export a symbol and
**silently overrides explicit `__attribute__((visibility("default")))`**.

Wine's `DECLSPEC_EXPORT` (include/winnt.h) picks the `visibility("default")`
branch, not the `__declspec` one, because clang satisfies the `__GNUC__ >= 3.3`
test first. So every Unix-side export compiled to `GLOBAL HIDDEN` and the
linker then localized it. The build was clean -- 0 errors, 8 targets, correct
sizes -- and `ntdll.so` exported **only libc**: `__wine_main` was `LOCAL
HIDDEN`, so `pw_prx_lookup(descriptor, "__wine_main")` would have found
nothing at runtime, with no build-time signal anywhere.

Fix: `-fno-visibility-from-dllstorageclass` in CFLAGS. Verified minimal case --
the attribute alone yields `GLOBAL HIDDEN`, with the flag it yields
`GLOBAL DEFAULT`.

⚠ Worth reporting upstream: any Wine-on-PS5 build hits this if Sony's clang
defaults match (it is a PS4/PS5 target feature, not an OpenOrbis one).

### The PRX stage is upstream's, not hand-rolled

`tools/build_wine_ps5.sh` skips its PRX stage on PS4 (`no built
ps5-native-tool` -- it needs ps5-native-app-boilerplate). Converting the `.so`
files directly with `create-fself` is **wrong**: exports come from a generated
**PRXDESC1 descriptor** (`tools/gen_prx_descriptor.py`), not the dynamic
symbol table, so a direct conversion yields a module exporting libc and
nothing prospero-win looks up.

`scripts/prx-ps4.sh` reproduces upstream's four steps, substituting
`create-fself -lib` for the PS5's `ps5-native-tool link --module` + `self
--sign`. Export lists are upstream's verbatim.

Things that had to be right:

- **`.data.sce_module_param` must be its own output section.** lld merges
  `.data.*` into `.data`, after which create-fself crashes rather than
  erroring: `panic: nil pointer dereference` at
  `OELFGenProgramHeaders.go:151`, because it looks the section up by name and
  dereferences nil. `src/freebsd-compat/prx_module_param.ld` keeps it with
  `KEEP` + `INSERT BEFORE .data`.
- **`crtlib.o`, not `crt1.o`** carries that section -- but it also defines
  `module_start`/`module_stop`, which the descriptor defines too. Extract the
  section alone: `llvm-objcopy --only-section=.data.sce_module_param`.
- **DT_NEEDED is what create-fself resolves imports through.** Without linking
  against the already-built modules it reports `missing library for symbol
  (RtlSetLastWin32Error)`. Modules must be built in dependency order, and the
  stub file must be named for the **soname** (`ntdll.prx`), which is what
  create-fself opens verbatim -- a `.so` next to it is not found.
- `libwineshim.a` (this port's stand-in for `wine/ps5/*`) must step aside when
  the real units are linked, or every `__wrap_*` is defined twice:
  `PW_PRX_LINK=1`.
- `link_objects()` drops absolute paths out of make.log, so ntdll's heap and
  direct-memory objects are named explicitly, as upstream's `link_prx` takes
  them as its `$3`.

Recorded dependency graph: `win32u → ntdll`; `opengl32 → ntdll, win32u`;
`ws2_32 → ntdll, win32u, wineserver`.

### Three more header gaps (same musl-vs-BSD shape)

- `RTLD_SELF` -- FreeBSD's `((void *)-3)`, absent from the SDK's dlfcn.h
- `termios` -- musl spells the speed fields `__c_ispeed`/`__c_ospeed`; BSD code
  uses `c_ispeed`/`c_ospeed`. The SDK struct has no member by the BSD name, so
  the macros cannot shadow anything.
- `sys/extattr.h` -- absent; Orbis carries no extattrs and prospero-win stubs
  every entry point, so declarations and namespace constants suffice.

Both resolved with `#include_next`, so the SDK header still leads.

`ptrace` needed a one-word patch to prospero-win instead: the PS4 SDK declares
the address argument `void *` where the PS5 uses `caddr_t`. Same ABI, but C
rejects the conflicting definition.
`src/prospero-win-patches-ps4/0001-compat-ptrace-signature-for-ps4-sdk.patch`.

`pw_wine_thread_set_priority` needed no porting at all: it is plain
`pthread_setschedparam`, and patch 0882 feeds it SCHED_RR with priorities
695-700 -- inside the 256-767 range measured on Orbis.

### Still unverified on hardware

**Nothing of the Wine build has run on the console.** The mcontext offset
remains a guess (+16 from FreeBSD vs the PS5's measured +64), and patch 0883's
assembly depends on the same number; `mc_len == 800` is the intended runtime
check.

## Cross-check against alechurri/nx-on-orbis (2026-10-07)

A port of the Eden Switch emulator to PS4 Pro, on the **same stack we use**:
OpenOrbis 0.5.4, orbis-sdk-v1 (orbis-compat), Mesa RADV, LLVM/libc++ 18. The
closest prior art to this project -- a large C++ codebase with a JIT running
natively on this exact console -- so its platform findings are directly
comparable. Three results:

### 1. The mcontext offset is 64, not 16 -- RESOLVED without a hardware probe

`frontend/ps4_platform.cpp`:

    // PS4 ucontext: 16-byte signal mask + 48 bytes of padding, then a FreeBSD amd64 mcontext.
    constexpr std::size_t Mc = 64;

So PS4 matches the PS5's measured +64 after all; **our +16 guess was wrong**,
and it would have produced garbage registers rather than an obvious failure.
They verified register order against FreeBSD releng/9.0
`sys/amd64/include/ucontext.h`, and every offset they publish -- rdi 8, rbx 64,
rbp 72, r15 120, trapno 128, addr 136, err 152, rip 160, cs 168, rflags 176,
rsp 184, ss 192 -- matches `struct pw_fbsd_mcontext` exactly. Only the base was
ever in doubt.

Fixing the offset also exposed a real error in our struct: it carried an
`mc_spare1[1]` that pushed `mc_fpstate` off its 16-byte alignment and made the
struct 816 bytes. Removed; `sizeof` is now exactly 800, which is what `mc_len`
must read. Patch 0883 takes the offset from the macro, so the correction
propagates with no edit to the patch.

They also note the SDK's `bits/signal.h` describes musl's Linux layout rather
than the kernel's context -- the same orbis-compat trap we hit elsewhere.

### 2. ⚠ OPEN RISK: faults may never reach sigaction on PS4

They install fault handlers with **`sceKernelInstallExceptionHandler`**, not
`sigaction`, and their dynarmic patch excludes the POSIX path outright:

    -elseif (UNIX AND NOT HAIKUOS)
    +elseif (UNIX AND NOT HAIKUOS AND NOT PS4)
    +    # (PS4: faults never reach sigaction there, and the ucontext layout differs; generic below)

**prospero-win uses `sigaction`** (patches 0610, 0710, 0883) and evidently
works on PS5. If this is a genuine PS4/PS5 divergence it hits the core of the
port: the DBT's guard pages, lazy commit, and every guest access violation
depend on SIGSEGV arriving.

Likely fix: install through `sceKernelInstallExceptionHandler` on PS4. The
handler signature is `void (*)(int signal, void *ucontext)` and the ucontext is
the same FreeBSD one, so everything above the offset is reusable. Testable on
hardware cheaply -- take a deliberate fault and see which handler runs.

### 3. They are running a PS4 Pro with the GPU configured as a base PS4

They use the stock orbis-sdk-v1 RADV, described as `"Liverpool" GFX7`. No
`gladius`, no `0x9924`, no `cu_bitmap` or `num_shader_engines` override
anywhere in the tree. `sceKernelIsNeoMode()` appears only in `probe/` to
*print* whether the console is a Pro -- it never reaches the GPU
configuration.

So this project leaves **half the Pro's CUs masked**, which is the bug
`patches/0001-orbis-gladius-neo-detection.patch` fixes: compute knee 72 -> 144
SIMDs, plateau 950 -> 1830 GFLOP/s. They are GPU- and memory-bound (a session
uses ~4.5 of ~4.6 GiB), so it should matter to them. A second independent
consumer of the patch, and a reason to get it upstream.

### Worth borrowing

- **~4.4 GiB usable via package layout** -- more than we have arranged; Wine
  will want it. Their `package-eden.sh` is the reference.
- Their `probe/probe.c` covers firmware, Neo mode, CPU/TSC clocks and boot
  memory pools -- overlapping our probe but wider on memory.
- GFX7 RADV hazard: an indirect draw with a count buffer **hangs the GPU**
  (`patches/eden/0009`). Relevant whenever we reach real rendering.

## Patch 0883's native path is dead code on PS4 (2026-10-07)

`native_libkernel_resolve()` does not merely call `sigaction` -- it resolves
**libkernel's raw sigaction stub** and calls that, because the libc wrapper is
not sufficient on PS5 either. The resolver is bound to one specific PS5
libkernel build:

- a 20-byte fingerprint of the module
- the module name **`libkernel.sprx`**
- an exact four-segment layout: offsets {0, 0x48000, 0x68000, 0x6c000},
  sizes {0x48000, 0x20000, 0x4000, 0x38000}, protections {4, 1, 1, 3}
- imports at `base+0xc3f0` / `base+0xde0`, entry points at `base+0x1600`
  (sigaction) and `base+0x2a0` (sigreturn)

Every one of those fails on PS4. So `pw_native_kernel.sigaction` stays NULL,
`PW_SIGNAL_HANDLER()` selects the non-native handlers, and the whole path falls
back to libc `sigaction` -- the one nx-on-orbis says never receives faults
here. **Upstream's PS5 signal design does not reach PS4 at all**, silently.

Note this also means the PS4 arm added to 0883 earlier (the mcontext offset
override) sits on a path that would never have run.

### The fix, at the seam that already existed

`pw_native_sigaction()` is the single point every handler registration goes
through, so the PS4 arm lives there: the five fault signals (SEGV, BUS, ILL,
FPE, TRAP) install via **`sceKernelInstallExceptionHandler`** -- the PS4 SDK
ships a `libkernel_exception.so` for exactly this, and `libkernel.so` exports
it, though no SDK header declares it. Sony hands the handler
`(int signal, void *ucontext)`; Wine wants `(int, siginfo_t *, void *)`, so a
trampoline synthesises the siginfo. `si_addr` is the only member the fault
paths read, and it is `mc_addr` at mcontext+136. Every other signal still goes
to `sigaction`.

Folded into 0883 rather than added as 0900: the series is capped at 0899 and
0880-0899 are contiguous, and 0883 is what introduces the seam anyway, so the
two PS4 arms belong together.

⚠ **UNVERIFIED. The switch is `PW_PS4_FAULTS_VIA_SONY` (default 1).** Title
**GLDS10004 "Gladius Fault Probe"** (`src/fault-probe`, built and packaged)
settles it in one run: it faults once under each mechanism on its own PROT_NONE
page, recovers by mprotecting the page so the instruction retries, and prints
which handler caught it plus `mc_len` at both +64 and +16. If sigaction turns
out to work, set the switch to 0 and the arm drops out entirely.

The probe reads only named offsets and trusts nothing until `mc_len` reads 800
-- the earlier signal probe scanned a range and took the title down.

## The title itself builds for PS4 (2026-10-07)

`GLDS10005` "Prospero Wine" -- `scripts/build-app-ps4.sh`, packaged at
`pkgout/wine-app/`, 10 MB, Neo attribute set, carrying all eight Wine PRX
modules in `sce_module/`.

Upstream builds the title with `tools/build_native.sh` against
`.deps/ps5-native-app-boilerplate`, which is PS5-only -- but **the title's entry
point is in the repo, not the boilerplate** (`native/wine64_main.c`, 1411
lines). The boilerplate only supplies PS5 packaging, which this port already
replaced. So the app was never actually gated on it.

**12 of the 13 files in `native/` compile for PS4 unmodified**, `wine64_main.c`
included. The one failure was `getdents`, declared locally because the PS5 SDK
omits it where the PS4 SDK declares it with `struct dirent *` and `size_t` --
the same shape as the `ptrace` conflict
(`src/prospero-win-patches-ps4/0002-*.patch`).

### What the binding file does

`src/native/pw_platform_bind_ps4.c` joins the contract to this port. The title
calls `pw_*_ps5_*`; our implementations are named `pw_*_ps4_*` because they were
written as standalone titles first. Upstream's pad/audio/hid cores compile with
their `*_HOST_TEST` guards so the PS5 vtables drop out, and the vtable entry
points land in the binding file instead.

⚠ `*_HOST_TEST` does **not** remove `platform_ops` -- it keeps it as a stub
returning `PW_ERR_UNSUPPORTED`, so the symbol still collides. The build renames
those two stubs aside with `llvm-objcopy --redefine-sym` rather than patching
upstream.

Video out needed a real adapter, not an alias: the contract's `PwVideoOutPs5`
carries `PwAgcPs5` state that the linear-scanout path has no equivalent for, and
its `present()` hand-rolls layout, background fill and a scaled blit through the
tiling tables. On PS4 that is exactly what the portable compositor already
writes, so `present()` is `pw_present_frame_from_view` +
`pw_videoout_ps4_present_scaled`, and the device state stays ours -- the
caller's struct is only a handle, never read by the title.

Not ported, and explicitly stubbed rather than left undefined so the title
starts and says so: **HID** (keyboard/mouse over USB -- the DualShock 4 arrives
through the pad path, which is ported) and **Lapy elevation** (a PS5 privilege
path; a PS4 title under GoldHEN already has what it needs).

### ⚠ What this package is NOT yet

It boots the launcher and exercises module loading. It cannot run a Windows
game: **the package carries no Wine prefix and no PE tree**. The build produces
16 patched PE DLLs (`i386-windows/` and `x86_64-windows/`) but a prefix needs
the whole Wine PE side plus NLS data, and `wowprospero.dll` -- the WoW64 CPU
backend, from `wine/wowprospero` via `tools/build_wowprospero.sh` -- is not
built yet either. Four of upstream's thirteen modules are still missing:
`wowprospero`, `wineps5`, `libfreetype`, `libvulkan`, `xinput1_3`.

So the first run tests: does the eboot start, does `ntdll.prx` load, does the
launcher render, and does the fault path survive -- not whether a game runs.

## Four findings from the nx-on-orbis developer (2026-10-07, by email)

They confirmed our GPU result from their side: *"in my runs the driver came up
with the base PS4 config (mesa.log reports the 18 CU / 72 TMU / 32 ROP spec, and
that value is a spec number, not measured from the hardware), so I never used
the Pro's full 36."* Their port is CPU-bound (0 ms GPU wait, emulated main core
~80% busy in JIT), so it cost them little -- but they want the patches:
*"your patches would matter for anything GPU-heavy, and I'd love to see them."*
The project is closed on their side and explicitly free to fork or reuse.

### 1. wchar_t: does NOT apply to us, and it is worth knowing why

Their report: the SDK's static `wmemchr`/`wmem*`/`wcs*` work on **16-bit**
units while clang's `wchar_t` is 32-bit, so with a newer libc++ `std::find` over
any 4-byte type lowers to `wmemchr` and **silently fails unless the match is the
first element**. They replaced them with 4-byte versions.

Checked here: the `x86_64-scei-ps4` target defines `__WCHAR_TYPE__` as
**`unsigned short`, 2 bytes** -- Sony's ABI default, not a flag we pass (bare
clang for the triple agrees; host Linux says 4). So the SDK's 16-bit routines
are correct for this target and the mismatch does not arise. Confirmed at the
artifact level: `wine_app.elf` and `ntdll.shared.elf` import **zero**
`wmem*`/`wcs*` symbols, Wine defines its own 40, and `liborbis-compat.a`
imports none.

⚠ It is still a tripwire: this holds only while `wchar_t` stays 16-bit here. Any
C++ built for this port with a different triple, or any libc++ code doing
`std::find` over a 4-byte type, brings it straight back -- and the failure is
silent.

### 2. ⚠ RADV flattens each submission into a 2 MiB staging buffer

524288 dwords; a bigger submission **hangs the GPU** (`mesa.log`: "submission
does not fit"). Their mitigation is submitting every 256 draws and after 96
render passes. Applies the moment this port renders anything real, and sits
alongside the other GFX7 hazard already recorded (an indirect draw with a count
buffer hangs the GPU).

### 3. Images cost direct memory on top of the arena

The driver takes one ONION arena (`ORBIS_ARENA_MIB`, default 1024; they ship
1280 because 1024 ran out). Images and other device-local buffers go to
**GARLIC memory allocated outside that arena**, costing direct memory on top of
it -- hundreds of MiB while a race loads. `ORBIS_VRAM_GARLIC=0` keeps them in
the arena instead. So the arena figure is not the memory budget.

Related trap they document: **`sceKernelAvailableDirectMemorySize` returns the
largest free block, not the total.**

### 4. Address space caps at 16 GiB per reservation

The largest single `sceKernelReserveVirtualRange` they got was **16 GiB**;
64 GiB fails with `0x8002000c`.

Checked against what prospero-win asks for, and we are well clear: the reserved
areas are `0x10000-0x68000000` (~1.6 GiB), `0x68000000-0x7f000000` (~368 MiB)
and `0x7f000000-0x7fff0000` (~15 MiB) -- the 32-bit guest's address space, all
far below the cap. It would only bite if this port ever wanted a fastmem-style
aliased view of guest memory, which is exactly what they tried and why they
measured it.

### Also worth having

- Threads get 2 MiB stacks and **64 KiB alternate signal stacks so a stack
  overflow can still report** -- directly relevant to our fault-handler work.
- Their `probe/probe.c` covers firmware, Neo mode, CPU/TSC clocks and boot
  memory pools.

## GoldHEN dies on ANY stray write to its FTP port (2026-10-07)

Known already: lftp's anonymous login kills GoldHEN. Today's addition is that it
is not the *login* that does it -- **one unexpected byte is enough**.

    echo > /dev/tcp/${PS4_HOST}/2121     # kills it

That opens the control socket and writes a newline. Both GoldHEN services (FTP
2121 and klog 3232) stopped accepting connections immediately afterwards while
the console kept pinging -- the same signature as the lftp failure.

The safe idioms, both already used by `scripts/preflight.sh` and
`scripts/arm.sh`, open the socket and send **nothing**:

    exec 3<>/dev/tcp/HOST/PORT          # bash, connect only
    socket.create_connection(...)        # python, connect only

⚠ So: **probe the console with `scripts/preflight.sh`, never with an ad-hoc
shell one-liner.** The repo's scripts were already correct here; this was a
hand-rolled check run around them. `preflight.sh` also carries a standing
warning against probing the klog port at all, for the same reason.

Recovery is manual: relaunch GoldHEN from the console.

## The fault path and the mcontext, MEASURED (2026-10-07, GLDS10004)

Two assumptions baked into this port were wrong. Both are now settled on
hardware by `src/fault-probe`, which faults once under each mechanism on its
own PROT_NONE page and recovers by mprotecting it so the instruction retries.

### sigaction DOES receive faults on PS4

    sony handler  : receives faults
    sigaction     : receives faults

Both fired. nx-on-orbis's *"faults never reach sigaction there"* does **not**
hold on this console -- their trouble was presumably specific to dynarmic's
handler rather than a platform limit. So patch 0883's PS4 arm is left in place
but **off** (`PW_PS4_FAULTS_VIA_SONY 0`): upstream's sigaction path works and
staying on it keeps the divergence smaller. `ntdll` no longer imports
`sceKernelInstallExceptionHandler` at all.

⚠ This is the second time a finding borrowed from that project did not survive
contact with our console. Their offset was right; this was not. Borrowed facts
are a reason to measure, not a substitute for it.

### The mcontext is at +64 and is 1152 bytes, not 800

`mc_len` read at eight candidate bases, and exactly one is plausible:

    base +0   -> 8593489920
    base +8   -> 16607277028999169
    base +16  -> 6                  (FreeBSD's own offset: garbage)
    base +32  -> 67
    base +48  -> 34074504448
    base +64  -> 1152               <-- plausible
    base +80  -> 131073
    base +96  -> 4218358

So +64 is confirmed, but **Orbis's mcontext_t is 1152 bytes** where FreeBSD 9's
is 800 -- 352 bytes larger, almost certainly a wider xsave area.
`struct pw_fbsd_mcontext` now carries an opaque `mc_tail` to that size; nothing
in the port reads past `mc_ownedfp`, so only the total needed fixing.

**The register block is byte-for-byte FreeBSD 9's**, confirmed field by field:

    mc_trapno  = 12            T_PAGEFLT
    mc_fs/mc_gs= 0x13 / 0x1b   valid selectors
    mc_addr    = 0x200364000   EXACTLY the faulting page
    mc_rip     = 0x405dfd      inside the eboot's text

(The probe's first report of `mc_trapno` as 7599905975566348 was its own bug:
it read 8 bytes at a 4-byte field, packing trapno|fs|gs together. 0x001b0013_0000000c
decodes to exactly the three values above -- which is itself a confirmation.)

### ⚠ Returning from main raises SIGSYS

Both runs ended the same way after `=== done ===`:

    # A user thread receives a fatal signal
    # signal: 12 (SIGSYS)        rip: 0x8000028bc

Restoring the handlers before returning did not prevent it, so it is not ours:
`rip` is outside the eboot, in a library, and SIGSYS is a rejected system call
-- the kernel kills a title that executes a syscall instruction outside
libkernel (the same rule patch 0690 is about). The static libc's exit path
appears to make one.

**Consequence: a title should not return from main.** Harmless in a probe that
has already printed everything, but the real title must not unwind out of
`main` and expect a clean exit.

## The title must not link against ntdll (2026-10-07, measured)

First run of GLDS10005 on hardware died at load:

    # exception: 0xa0020101 (PRX_NOT_RESOLVED_FUNCTION)

and the loaded-module list contained **none of our nine PRX modules** -- only
Sony's `libc.prx` and `libSceFios2.prx`.

Two mistakes, both from linking the title against `prx/stubs/ntdll.so`:

1. **The console does not auto-load `/app0/sce_module/*.prx` to satisfy a
   DT_NEEDED on a non-Sony module.** Sony's own modules load; ours did not, so
   every symbol the title imported from `ntdll.prx` was unresolved before
   `main()`.
2. **The dependency should not exist at all.** prospero-win resolves Wine's
   entry points at RUNTIME through its own loader --
   `src/pw_wine_start.c`: `pw_prx_lookup(descriptor, "__wine_main")` -- so the
   title loads the modules itself and looks symbols up by name.

Worse, the stub link was silently binding the wrong things: the title's 212
undefined symbols were **C++ runtime** (`_ZNSt3__1...`, `_Unwind_*`, `_Exit`),
not Wine at all. Every PRX carries orbis-compat and libc++ whole-archive, so
the linker happily resolved the title's C++ runtime out of `ntdll.prx` instead
of the SDK's. The title now links against Sony libraries only.

One real dependency came out of this: `wine/ps5/pw_wine_prx.c` -- the PRX
loader -- has to be compiled **into the title**. It is what loads the modules,
so it cannot be imported from one.

## prospero-win's launcher runs on the PS4 (2026-10-07)

First real milestone of the port. GLDS10005 renders the launcher -- a Windows
desktop -- on hardware, with upstream's own title code:

    HELLO ps5log/1 title=PPSA99995 app=prospero-win-wine64 tag=ps4-gladius
    PW_WINE64 data_mount   data_after=1 root=/data/prospero-win
    PW_WINE64 library      status=not-found scan_errno=2 entries=0 games=0
    PW_WINE64 args         argc=1 mode=launcher
    PW_WINE64 hid          no PS4 implementation, continuing without keyboard or mouse
    PW_WINE64 launcher     video=ok pad=ok hid=precondition frame=1 apps=0

Every line is correct. `library status=not-found` (errno 2, ENOENT) is simply
that no game library has been pushed yet, and `apps=0` follows from it. The hid
line is this port's own stub reporting itself.

**`video=ok pad=ok` and a drawn frame** means `src/native/pw_videoout_ps4.c` and
`pw_pad_ps4.c` are driving *upstream's* title through the PS5 contract, not our
own test harness: direct memory -> linear scanout -> the portable compositor ->
`sceVideoOutSubmitFlip`, with the binding layer
(`src/native/pw_platform_bind_ps4.c`) joining the two.

The nine PRX modules are in the package but not yet exercised; they load when a
game launches.

### Three bugs stood between a working title and seeing it work

The title had been running the launcher for **five launches** before any of
this was visible. Nothing was wrong with it; the problem was entirely in our
view of it, and each cause was silent by design:

1. **ps5log picked the POSIX network backend.** It is a single-header library
   whose hooks are `#ifndef`-guarded and chosen by what is included *before*
   it. Nothing in the title includes `ps5log_ps5_net.h`, so it compiled against
   `socket`/`connect`/`fcntl` -- which on Orbis are not sceNet. It opened a
   socket that could never connect, took its "connect refused" path, and stored
   the reason in a struct nobody reads.
2. **Nothing calls `sceNetInit`.** Neither ps5log nor `wine64_main.c`; on PS5
   the system evidently does it for a title.
3. **`__attribute__((constructor))` is silently dead in an OpenOrbis eboot.**
   The `.init_array` section exists and holds the entry, but `crt1.o` never
   walks it. What `crt1.o` does carry is a **weak undefined `_init`**, which it
   calls when something defines it -- that is the startup hook on this SDK.

⚠ **Keep a log channel that cannot fail.** `sceKernelDebugOutText` needs no
library, no configuration and no network, so it still reports when the
configured channel is itself the broken thing. The `_init` breadcrumb is
permanent for that reason: four launches were spent blind for want of it.

## Where it stands: dynamic TLS across modules (2026-10-07, end of day)

Wine runs on the PS4. It completes `init_paths`, `virtual_init`,
`init_environment`, `start_main_thread`, `virtual_alloc_first_teb` and
`dbg_init`, and stops inside `server_init_process`:

    PW_WINE64 fault signal=0xb addr=0x0 rip=0x800c99c4d
      module=/app0/win/wine/lib/wine/x86_64-unix/wineserver.so
      module_offset=0xf5c4d

Symbolised, that is `strerror+0x13`, and the instruction is:

    callq  __tls_get_addr
    cmpq   $0x0, (%rax)        <-- rax is NULL

**`__tls_get_addr` returns NULL in a PRX.** `strerror` only happens to be the
victim: it reads musl's thread-local locale pointer. Anything touching dynamic
TLS inside a module will fault the same way.

### Why, and why it keeps coming back

The SDK ships libc **only as a static archive**. Every PRX therefore carries a
private libc with its own thread-local bookkeeping, and the thread running Wine
was created by the *title's* libc. The module's `__tls_get_addr` consults a DTV
its own copy never initialised for that thread.

This is the fourth distinct failure from that one fact, and each looked
unrelated:

1. modules exported libc, so the eboot bound its C runtime to `ntdll.prx`
2. the title's `setenv` and Wine's `getenv` used different environments
3. `wineserver.prx` imported 123 libc symbols from `ntdll.prx`
4. dynamic TLS has no valid DTV in a module

### The options, none free

- **Link the shared libc** (`libSceLibcInternal`, the stub for the `libc.prx`
  the process already loads). This is almost certainly how PS5 avoids all four:
  one libc, one TLS regime. Tried once and reverted -- it pulled 88 symbols
  including `malloc`, `exit` and the `__cxa_*` family, and the title died with
  `PRX_NOT_RESOLVED_FUNCTION`. Worth retrying now that the link order is fixed,
  since that earlier attempt also had problem (3) in play.
- **Force initial-exec TLS** (`-ftls-model=initial-exec`) so accesses skip
  `__tls_get_addr`. Does not help here: `strerror` comes from the prebuilt
  `libc.a`, which we cannot recompile.
- **Supply our own `__tls_get_addr`** in each module, backed by that module's
  own TLS segment. Self-contained, but it is a runtime-internals
  reimplementation and would need care around thread creation and teardown.

The first is the principled fix and the one to try next.

### Worth keeping regardless

`module=`/`module_offset=` in the emergency line is what made this findable at
all; a bare `rip` named nothing once faults moved outside ntdll. Any address in
a loaded module can now be symbolised against the unstripped `.shared.elf` kept
in `.deps/wine-ps5/prx/`.

## The shared libc fixes dynamic TLS (2026-10-07)

`PW_SHARED_LIBC=1` resolves libc from `libSceLibcInternal` instead of the static
archive, so the title and every PRX share one libc -- one `environ`, one TLS
regime. `ntdll.prx` no longer defines `__tls_get_addr` at all.

**It works.** Wine now gets *through* `server_init_process` without faulting,
and the whole class of four static-libc failures goes with it. The earlier
attempt failed for reasons since fixed: the link order that had modules binding
their C runtime to ntdll, `LDLIBS` being single-quoted so the switch never
expanded, and the missing late archive pass `__inet_aton` needs.

### What stops it now: Wine exits silently

    WINE wine startup: server_init_process
    PW_WINE64 exit sink_calls=7
    PW_WINE64 restart to=launcher cycle=1 reason=wine-exit

`reason=wine-exit` is `__wine_main` returning, not a fault. `sink_calls=7`
accounts for exactly the seven startup lines above it, so Wine shut down
deliberately and said nothing.

### ⚠ Wine's debug channels are not usable yet

Setting `WINEDEBUG=+server,+seh,+process,+module` changes the outcome from a
clean exit to:

    signal: 12 (SIGSYS)   rip: 0x8000028bc

the same address and signal the fault probe hit at exit this afternoon. SIGSYS
here is the kernel killing a title for executing a `syscall` instruction
outside libkernel -- patch 0690's subject. So the tracing path reaches code
that issues a raw syscall, and turning the channels on destabilises rather than
illuminates. Reverted.

That it changed the outcome at all confirms the environment now reaches Wine,
which is itself the shared-libc fix working.

### Next

1. Find why `__wine_main` returns. The silent exit is the blocker; Wine's own
   tracing is currently unavailable, so the next lever is either the raw-syscall
   problem (so channels become usable) or instrumenting the return path
   directly.
2. The raw-syscall/SIGSYS issue is worth solving on its own: it is the same
   fault that kills a title returning from `main`, and it will keep appearing.

## The SIGSYS was fatal_error; the real failure is create_server_dir (2026-10-07)

SIGSYS is **not catchable** on this kernel -- it kills the title before any
handler runs, so installing one changed nothing. What does work: the crash dump
carries a **dynamic libraries** section listing every module's text range, and
the title now logs its own segment bases at load, so klog's backtrace can be
symbolised afterwards against the unstripped `.shared.elf` files.

Doing that turned a bare list of addresses into:

    wineserver+0x8a0e6   fatal_error
    wineserver+0x8ba16   create_server_dir
    wineserver+0x8bc52   open_master_socket
    wineserver+0x69a63   start_inprocess_server
    ntdll+0x7e507        connect_inprocess_server
    ntdll+0x7cc25        server_connect
    ntdll+0x6d544        start_main_thread

So the SIGSYS is a **red herring**: `create_server_dir` fails, calls
`fatal_error`, and `fatal_error` dies trying to write its message to a stderr
that goes nowhere on this console. The message that would have told us
everything is the thing that killed the process.

### ⚠ A prefix written over FTP is not writable by the title

Same ownership problem seen earlier in reverse: `/data/prospero-win` was created
by the title and the FTP server could not write into it until `SITE CHMOD 777`.
The prefix pushed by `pw_prefix.py` belongs to the FTP server, and the title
has to create its server directory inside it. Chmod the library root, the
prefix and its drive_c after any push.

### Also confirmed by this dump

`libSceLibcInternal.sprx` **is loaded** (text 0x800090000-0x8001b8000), which
settles the doubt about whether `PW_SHARED_LIBC` could bind at runtime. It can,
and does.

### Worth keeping

Logging module segment bases at load costs three lines and is the only reason
an uncatchable crash is diagnosable at all. Combined with the dump's own module
list, any address in any module can be named after the fact.

## wineserver: st_dev is not stable (2026-10-07, where it stands)

With `fatal_error` routed to klog (patch 0113), the message that had been
discarded all evening appeared on the first run:

    wineserver: chdir did not end up in
      /data/prospero-win/prefixes/oblivion/.wineserver/server-290bff49-7e78bd

`create_server_dir` creates the directory, `chdir`s in, `open(".")`s it and
compares `st_dev`/`st_ino` against the directory it just made.

Fixed one cause: `pw_cwd_join` turned a relative `"."` into `"<cwd>/."`, which
this console does not resolve back to the same inode. `"."` now collapses to
the base (`src/prospero-win-patches-ps4/0006-*`).

**Still failing, and the reason is sharper.** The server directory is named
`server-<st_dev>-<st_ino>` of the prefix, and that name changes between runs:

    run 1   server-290bff49-7e78bd
    run 2   server-290bff65-7e78bd

`st_ino` is stable; **`st_dev` drifts**. So `stat` and `fstat` disagree about
the same directory, and the comparison can never hold.

Not an interposition failure: `stat` and `fstat` in wineserver are
orbis-compat's corrected versions (it documents that the SDK's `struct stat`
does not match the layout the PS4 kernel fills, with the shear measured on
`st_size` and `st_mode`), and `__real_stat` from the cwd layer's `--wrap`
reaches them.

### Next

- Measure `stat` vs `fstat` on one directory directly, in a probe: both
  structures, field by field. That settles whether `st_dev` is volatile from
  the kernel or mistranslated on one of the two paths.
- orbis-compat's note covers `st_size` and `st_mode` only. If `st_dev` is
  junk on this file system, the fix is to drop it from the comparison and the
  directory name, which is a small Wine patch and arguably correct anyway --
  a prefix cannot span devices here.

### The lesson that keeps repeating

Four of today's blockers were invisible until the instrument was fixed:
`module=`/`module_offset=` on faults, module bases logged at load, reading a
format string out of the binary, and now `fatal_error` reaching klog. On this
console every default diagnostic channel is broken in a way that looks exactly
like the program failing silently.

## Two findings from auditing against orbis-compat (2026-10-07)

Zak asked whether orbis-compat's notes cover anything else we are getting
wrong. They cover two things, one already solved our way and one a live bug.

### ⚠ The 32-bit wide-character functions were WRONG for this target

`orbis_wchar32.o` replaces the SDK's `wmemchr`/`wcslen`/`wmemcmp` with 32-bit
`wchar_t` versions. That is correct for the target orbis-compat measured --
`x86_64-pc-freebsd12-elf`, where clang says `wchar_t` is 32-bit while the SDK's
C headers say 16, so C and C++ disagree.

**This port targets `x86_64-scei-ps4`, where clang says 16-bit and the headers
agree.** Linking those definitions gave Wine, whose `WCHAR` is 16-bit, a
`wcslen` that steps four bytes at a time. Verified in the binary before the
fix:

    wcslen   cmpl $0x0, 0x4(%rdi,%rax)      <- 4-byte stride
    wmemchr  cmpl %esi, (%rax)              <- 32-bit compare

and ntdll calls `wcslen`, `wmemchr` and `wmemcmp`. Nothing had failed loudly
yet; this is the silent-corruption shape the nx-on-orbis developer warned about,
arriving from the opposite direction.

Fixed by linking a copy of `liborbis-compat.a` with `orbis_wchar32.o` removed
(`build/ps4-wine-sdk/liborbis-compat-16bit-wchar.a`), so the SDK's own 16-bit
routines are used. ⚠ Anything else built for this target against orbis-compat
has the same problem.

### The environment finding was already ours, independently

`orbis_env.cpp` documents exactly what cost an hour tonight -- "setenv() in one
image is invisible to another", same cause, the SDK's real static musl giving
every image its own `environ`. Their fix answers operator knobs from env files;
ours hands the module the values, which their own note calls "the honest
mechanism". No change needed.

## ⚠ Descriptor duplication is refused outright

`dup_fd_object` (server/fd.c:1885) cannot duplicate a descriptor by any means
this console offers:

    dup()                 EPERM
    fcntl(F_DUPFD)        EINVAL
    dup2() onto a free fd fails for every candidate 64..255
    sceKernelRdup()       EPERM

orbis-compat records `dup2` onto fd 1 or 2 as EPERM -- "the descriptor table is
not ours to rearrange". This is broader: it is the whole table, and
`sceKernelRdup`, the libkernel primitive that exists precisely for this, is
refused as well.

That is structural rather than another small mismatch. wineserver duplicates
descriptors routinely, so the options are:

1. Find out whether the refusal is specific to the descriptor being duplicated
   (this one comes from `shm_open(SHM_ANON)`) or applies to every fd. A probe
   that dups a regular file, a directory and an shm fd settles it in one run.
2. If it is universal, patch the server to share the descriptor instead of
   duplicating it where ownership allows -- a real design change, not a
   one-liner.

## MEASURED: descriptors cannot be duplicated on this console at all

`src/dup-probe` (GLDS10008), four mechanisms against five descriptor kinds:

| descriptor | dup | fcntl(F_DUPFD) | dup2 | sceKernelRdup |
|---|---|---|---|---|
| regular file | fail | fail | fail | EPERM |
| directory | fail | fail | fail | EPERM |
| shm SHM_ANON | fail | fail | fail | EPERM |
| unix socket | fail | fail | fail | EPERM |
| pipe | fail | fail | fail | EPERM |

Identical for every kind, so this is **not** specific to anonymous mappings.
orbis-compat's "the descriptor table is not ours to rearrange" is literal and
complete: not dup, not dup2, not F_DUPFD, and not `sceKernelRdup` -- the
libkernel primitive that exists for exactly this.

Also measured: **`fcntl(F_GETFD)` on fd 0 returns -1**, so fcntl is broadly
unsupported. Any logic that probes for a free descriptor number this way is
meaningless, including the dup2 fallback tried earlier tonight.

⚠ Probe reporting bug, to fix if it is rerun: the SCE-error decoder treats any
value >= 0x80000000 as `0x8002_0000 | errno`, so a plain POSIX -1 prints as
"SCE 0xffffffff (errno 65535)" and the real errno is lost. Only
`sceKernelRdup`'s 0x80020001 is a genuine SCE code. The conclusion is unchanged
-- everything fails -- but the errnos for the first three columns are not known.

### What this means for wineserver

`dup_fd_object` (server/fd.c:1885) cannot work here, and it is not a corner:
Wine's server duplicates descriptors as a matter of course. The options are

1. **Share instead of duplicate.** On PROSPERO, have `dup_fd_object` take a
   reference to the same unix fd rather than a new one, with the owner
   responsible for the single close. Correct only where no caller depends on
   independent file offsets or close semantics -- which has to be checked per
   call site, not assumed.
2. **Avoid the path for the mapping case only.** `create_user_data_mapping` is
   the first caller to fail; a mapping could hold its fd directly. Smaller, but
   leaves every other caller waiting to fail.

Option 1 is the honest fix and is a design change, not a patch. This is the
right place to stop and think rather than keep adding fallbacks.

## Where tomorrow starts (end of 2026-10-07)

Built and packaged, **not yet run** -- the console went off before this could
be tested. `pkgout/wine-app/` is current with its inputs; `scripts/deploy.sh`
will refuse it if that ever stops being true.

### The pending change

`0735-server-share-the-fd-for-a-mapping.patch`. The chain that led to it:

    release_object(NULL) in init_directories      (directory.c:479)
      <- create_fd_mapping, the NLS file mapping
        <- dup_fd_object failed                    (fd.c)
          <- dup/dup2/fcntl(F_DUPFD)/sceKernelRdup all refused
          <- and the fd has NO unix_name, so reopening was impossible

`get_fd_object_for_mapping` already shares an fd when one matches on access and
sharing; it only falls through to `dup_fd_object` when none matches exactly.
A mapping never seeks, so the offset a duplicate would own is never used.
The patch takes the original fd in that case.

**First thing tomorrow: install and launch.** If the NLS mapping succeeds,
`init_directories` finishes and the server reaches the point of accepting
ntdll's connection.

### What to expect after that

`dup_fd_object` has two other callers that will fail the same way, and neither
is fixed:

- `file.c:162` create_file_obj -- a real file open. It HAS a unix_name, so the
  reopen path in 0734 should cover it. Unproven.
- `sock.c:2149` accepting a deferred connection -- a socket has no name and
  cannot be duplicated. Nothing covers this yet; sharing is wrong there because
  the accepted socket must be independently closable.

### Diagnostics now in place (all permanent)

| what | gives |
|---|---|
| `module=`/`module_offset=` on faults | which module an address is in |
| module segment bases logged at load | mapping klog backtraces |
| `fatal_error` -> klog (0113) | wineserver's own error messages |
| `file_set_error` errno + caller (0733) | the failing syscall behind an NTSTATUS |
| `release_object(NULL)` + status (0732) | which create_* failed and why |
| **anchor addresses** in both reports | the module base, even on a clean exit |

The anchor is the one to remember: module bases move between runs, and a clean
exit leaves no crash dump to derive them from. `base = anchor - <symbol offset
in the unstripped .shared.elf>`; both anchors agreed on 0x800b3c000 tonight.

### The title cannot be moved off 0x400000, and that is where 32-bit games live

A 32-bit Windows executable is based at `0x400000`. Where its relocations are
stripped — `IMAGE_FILE_RELOCS_STRIPPED`, which is the norm for pre-2008 games,
Oblivion.exe among them — it cannot be loaded anywhere else, and Wine says so:

```
wine: failed to create main module for "C:\Games\Oblivion\Oblivion.exe",
      status c0000018            (STATUS_CONFLICTING_ADDRESSES)
```

The console loads this title at `0x400000` too, spanning `0x400000-0x55c000`.
Three ways to move it were measured, and none works:

- **A base in the ELF does not move a PIE.** The loader adds its own bias on
  top of it. A title based at `0x200000000` was entered at `0x400479_0a8` —
  `0x200000000 + 0x200000000 + 0x400000 + entry` — and died on an unmapped page.
- **ET_EXEC is refused outright**, at any address. `0x200000000`,
  `0x100000000` and `0x400000` all end the same way, with the loader placing
  the image correctly and then failing to read the process parameter block out
  of it:
  `### copyin=0xe uaddr=0x49c860` then `0xa0020105 PRX_INVALID_IMAGE`. `0xe` is
  EFAULT and the address is inside the title's own data segment each time, so
  the base was honoured and the ELF type is what the loader cannot take.
- **Nothing asks for a load address.** `create-fself` has no such option
  (`-ptype` is constrained to `fake` anyway), and the process parameter block
  has no such field — its four unknown slots are zero in the SDK's own object,
  and `orbis_sce_params.h` warns against inventing a meaning for them.

Clearing only the low 2 GiB would not have been enough regardless:
Oblivion.exe is `LARGE_ADDRESS_AWARE`, so under WoW64 it may use the whole
4 GiB.

**What still works:** any game whose image carries relocations. Wine maps it
elsewhere and patch 0130's `STATUS_IMAGE_NOT_AT_BASE` arm already forgives the
move. The limit is specific to stripped-relocation images based inside
`0x400000-0x55c000`.

**Upstream has the same conflict and solves it by moving the title.** PS5 is not
exempt: patch 0130 exists because "the title's image may hold 0x400000", and
`prospero-win/docs/DEVELOPMENT.md` says what they do about it --

> The runtime title uses the pinned foundation's high-address native layout:
> its executable segments begin at 4 GiB, leaving `0x00400000` available for
> Windows games that cannot be relocated.

-- which is the same 4 GiB this port tried to reach. They get it from
`ps5-native-tool`, the native converter in ps5-native-app-boilerplate, which
emits those segment addresses. That tool has no PS4 build, which is why
`scripts/prx-ps4.sh` substitutes `create-fself`, and `create-fself` plus this
kernel gives a PIE at 0x400000 with a bias added to any base asked for.

So the target is right and only the mechanism is missing.

**The remaining idea, untried:** this console does place code high -- our own
PRXs load at 0x800000000 -- just not the main executable. So move every line of
the title's code into a PRX, leave the eboot a stub that does nothing but load
it and call in, and unmap 0x400000 from inside the PRX once control has
transferred. That is the PS4 analogue of what ps5-native-tool does natively.
Whether the loader tolerates the main image being unmapped is unknown, and the
libc parameter block lives in the eboot's data, so Sony's libc may follow a
pointer into it later.

## The server died on an fd it never gave a user to (2026-10-08)

GTA IV got all the way to loading Windows DLLs -- `GTAIV.exe` at `00D90000`,
then 32-bit `ntdll`, `kernelbase`, `kernel32` -- and then wineserver died. The
request trace (patch 0748) ended on the same four every time:

    64 open_mapping -> 65 get_mapping_info -> 48 get_handle_fd -> 67 map_view

with request 48, `REQ_get_handle_fd`, never returning.

Three launches were spent before the real fault was visible, because every one
of them reported the *messenger* instead. The server's own thread has no Wine
thread data -- `pthread_getspecific` returns NULL -- so the fault handler's
attempt to describe the fault faulted in turn, at `0x7c` in
`__wine_dbg_header`'s `get_info()`, then `0x1c` in `PsGetCurrentThreadId`, then
`0x1c` in `server_call_unlocked`, that last one reached through
`segv_handler -> setup_raise_exception -> send_debug_event -> NtTerminateProcess
-> wine_server_call`. **Wine's entire exception path assumes it is running on a
Wine thread.** Patches 0612 and 0749 guard the three sites we hit; the general
problem is upstream's and worth reporting.

With 0612 in place the original fault finally printed:

    wineserver: FAULT on a thread without Wine data: sig 11 addr 10 rip 800b9bae9

`rip` less the wineserver.prx text base `0x800b3c000` resolves to
`req_get_handle_fd+0x79`, `server/fd.c:3312`:

    reply->type = fd->fd_ops->get_fd_type( fd );

`get_fd_type` is the third pointer in `struct fd_ops`, so its offset is `0x10`
-- exactly the faulting address. `fd->fd_ops` was NULL.

### Where an ownerless fd comes from

`load_intl_file()` returns `l_intl.nls` straight out of `open_fd()` and never
calls `set_fd_user()`. That is deliberate upstream: the server reaches that fd
only through `get_unix_fd()` and `pread()` to build the casemap table, and when
it hands the fd to `create_fd_mapping()`, `mapping_init()` calls
`dup_fd_object()`, which builds a **separate** fd, and gives *that* one
`mapping_fd_ops`. The ownerless original is never reachable by handle.

Neither path left on this console builds anything:

* `get_fd_object_for_mapping()` walks the inode's open list and `grab_object()`s
  a matching fd -- the original, with whatever user it had.
* the fallback added in 0735 does the same explicitly, because no descriptor
  here can be duplicated at all (`src/dup-probe`), and because the NLS file has
  no `unix_name` for 0734's reopen-instead-of-dup to use.

0735 skipped `set_fd_user()` on purpose -- an fd that already belongs to a file
object must keep its own ops, and `set_fd_user()` asserts on a second call. The
case it did not account for is the fd that belongs to *nobody*, which is
precisely the fd its own comment names. A mapping is reachable by handle, so the
moment a client asked for the NLS section the server dereferenced NULL.

Patch 0871 installs `mapping_fd_ops` only when the slot is empty, after both
paths rather than inside the fallback, since both can return the original.

### The audit

Every fd-creating call site in the server was checked, not just the one that
crashed. `alloc_pseudo_fd()` and `create_anonymous_fd()` take the ops as an
argument and every caller passes them, with one apparent exception --
`d3dkmt.c:519` passes NULL -- which sets `d3dkmt_fd_ops` before the fd can reach
an object, and releases it otherwise. Of the three `open_fd()` callers,
`file.c:252` goes through `create_file_obj()` and `device.c:409` sets the user on
the next line. **`load_intl_file()` is the only ownerless fd in the server, and
`mapping_init()` is the only place it becomes handle-reachable.** One fix closes
the whole class.

### Worth reporting upstream

`REQ_get_handle_fd` dereferences `fd->fd_ops` with no NULL check, and it is the
only `fd->fd_ops->` use in `server/fd.c` that checks neither the pointer nor the
member -- every other site guards with `if (fd->fd_ops->member)`, which still
assumes `fd_ops` itself. On a build where an ownerless fd can reach a handle
this is a server-killing NULL dereference rather than an error return.

## readdir does not list /data, and it cost GTA IV every import (2026-10-08)

With patch 0871 in, GTA IV's own startup ran -- opening files, mapping its
archives, reading the registry -- and then the process ended with no
explanation. The log stopped mid-startup and the native alive ticks stopped at
the same instant, which read as a hang on a shared lock. It was neither.

**The instrument was lying.** `pw_diagnostics_log` buffers into a 64 KiB
`pending` and writes only on `flush()`, which runs on a 100 ms tick or at
`pw_diagnostics_close`. A process Wine terminates returns to neither, so
everything still buffered is dropped -- and the runs worth reading are exactly
those. One buffer explained both symptoms: the Wine records and the alive ticks
were simply never written. Flushing per record took the session log from 4.7 KB
to 115 KB and the answer was in the part that had always been discarded:

    err:module:import_dll Library USER32.dll (needed by GTAIV.exe) not found
    err:module:import_dll Library PSAPI.DLL  (needed by GTAIV.exe) not found
    err:module:loader_init Importing dlls for GTAIV.exe failed, status c0000135

Twenty-one imports, every one of them.

### The shape that pointed the wrong way

`USER32.dll` failed instantly while `user32.dll` loaded moments later at
7B720000 -- the same file, differing only in case, requested by another builtin
whose import table spells it in lower case. Fourteen modules loaded that way;
every name a game spelled itself failed. That looks exactly like a case-folding
bug, and four candidates were ruled out before touching anything:

* `find_builtin_dll` already lowercases its path (`loader.c:1176`), so the
  builtin search is not it.
* `ntdll_wcsnicmp` disassembles to 16-bit loads folding through Wine's
  `uctable` -- **not** another instance of the `orbis_wchar32.o` `wchar_t`
  width bug, though that finding warned it would spread.
* `get_dir_case_sensitivity` returns TRUE, so `file.c:3119` enters the scan
  rather than skipping it.
* All 851 files are present in the prefix's `syswow64`.

Patch 0872 reported what the scan actually answered:

    ps5 scan: dir ".../dosdevices/c:/windows/syswow64" want L"USER32.dll"
              -> ret -1 errno 22 (root_fd -100)

`EINVAL`, and **every** call failed that way -- including lower-case
`kernel32.dll`. Not case at all. `pw_cwd_scan_directory` was broken for every
input, and the case-insensitive search is simply its only caller, so it is the
only thing that ever noticed.

### The cause was already written down in this repo

Compiling `pw_wine_cwd.c` on the host and running the failing paths through
`pw_cwd_resolve_at`, `pw_cwd_follow` and `pw_cwd_fold` cleared all three, which
left the one console-specific step. `read_names` listed with
`fdopendir`/`readdir`, and `native/pw_wine_library.c:108` had already measured
why that cannot work:

> The buffer is a whole directory block: libc's readdir reads with one at
> least a page (16 KiB on the console), and /data's directories use 64 KiB
> blocks, while a 4 KiB buffer got EINVAL there.

The launcher hit this months earlier, wrote the note, and answered it with
`getdents` over a whole 64 KiB block. The cwd layer never got the same
treatment. `read_names` now uses that method first and keeps libc's as the
fallback -- and keeps **every** entry, directories included, where the
launcher's parser deliberately drops all but `DT_UNKNOWN` and `DT_REG`: these
names are what resolves the components of a path, and without them `\windows`
and `\syswow64` disappear along with the files.

Two smaller faults of the same family went with it: the old loop returned
success when `readdir` failed part-way (`readdir` ends by returning NULL, and
only `errno` says which end), and on failure it left the half-built buffer to
the caller.

### The lesson, again

The instrument was wrong before the code was. Three launches read as "the game
goes quiet and exits", and the quiet was the log dropping its tail. The symptom
that survived -- upper case fails, lower case works -- was real but was a
consequence, and would have sent anyone into Wine's case folding, which was
correct the whole time. Check what the repo already measured: the answer had
been sitting in a comment in the launcher.

## The server was the last component on the console's own allocator (2026-10-08)

With the getdents fix in, GTA IV resolved its imports and reached 30 modules --
and then every further builtin was refused with `STATUS_NO_MEMORY`. wmvcore,
powrprof, oleaut32, dinput8, wintrust, shell32, and the set moved between runs.

### Four wrong answers, and what each cost

The symptom pointed in several plausible directions and I followed three of them
before instrumenting properly. Recording them because each looked right:

* **The 64 KiB dirents malloc.** The getdents fix allocated a whole directory
  block per lookup, and this console's libc refuses allocations that size. A
  real defect -- the launcher has always kept that buffer `static` -- and fixed,
  but not this. Patch 0872 reported **zero** refused scans afterwards.
* **The reserved-area budget.** An image view can only be placed inside a
  reserved area here, so a short reservation would look exactly like this.
  Patch 0873 printed the areas on the first unplaceable image and never fired:
  the image was never reaching `map_image_view` at all.
* **The listing cache.** `read_names` previously failed on every call, so
  nothing was ever cached; making it work gave `pw_wine_heap` a tenant it never
  had. The heap counters answered flatly: **181 KiB live, 1184 KiB mapped,
  zero failures** at the moment of refusal.
* **A single large block.** The libc allocator refuses sizeable blocks outright
  (`calloc` of 145 KiB answers EINVAL), so the refusal might have been one big
  request rather than exhaustion. This is why the server was instrumented
  instead of simply being moved to the other heap -- the two need different
  fixes and look identical from the client.

### The answer

Patch 0875 put the report at the source, in the server's `mem_alloc`:

    wineserver: mem_alloc refused 52 bytes (errno 0) after 100565 calls,
                10322 KiB asked

**52 bytes.** Not a large block: the arena was simply full, at the ~13 MiB
ceiling `pw_wine_heap.h` documents for the title's libc.

`scripts/prx-ps4.sh` linked that heap into **ntdll alone**:

    [ "$name" = ntdll ] && shim_objs="$heap $dmem $prx/obj/pw_prx_env_ps4.o"

so `wineserver.shared.elf` carried `U malloc`, `U calloc`, `U realloc`, `U free`
and took them from the shared libc -- the exact allocator `pw_wine_heap` exists
to escape. `-Bsymbolic` and archive semantics hid it: `malloc` resolved
dynamically to the shared libc, so the `pw_wine_heap_libc.o` member in
`libwineshim.a` was never pulled.

Upstream had already said what to do. `wine/ps5/pw_wine_heap_libc.c`, first
paragraph:

> ntdll.so links this file and exports it, so win32u.so binds its malloc family
> to the same heap; **the in-process wineserver links its own copy**.

The PS4 PRX script simply never implemented that half. It does now;
`pw_wine_heap` takes its memory from anonymous `mmap` in 1 MiB pieces, so the
server draws on the title's flexible memory rather than a fixed 13 MiB arena.

### The lesson

Instrument the component that sets the error, not the one that reports it. The
status surfaced in ntdll, three call layers from where it was decided, and every
theory formed on the client side was wrong. One line in the server's allocator
answered it outright -- and the fix was a sentence in a header comment that had
been there all along.

### The heap fix landed, and the last import was never DXVK

Linking `pw_wine_heap` into wineserver ended the `STATUS_NO_MEMORY` wall at a
stroke: modules went 30 -> 40 and every one of GTA IV's imports resolved except
one. `d3d9.dll`, reported as not found, with `d3d9=n` in the profile.

The file was there -- 1,740,962 bytes in the prefix's `syswow64`, i386, base
`0x10000000`, byte-identical on the console. Its imports say what it actually
is:

    kernel32.dll  ntdll.dll  ucrtbase.dll  wined3d.dll

`wined3d.dll` is Wine's own d3d9. DXVK's imports `dxgi` and `vulkan-1` and
never touches wined3d. The same is true of `d3d11.dll` and `dxgi.dll` beside
it, and of the oblivion prefix they were copied from: **there is no DXVK
anywhere on this host.** They were Wine's builtins all along, copied under
DXVK's name.

`n` means native only, so Wine found its own builtin, refused it for being a
builtin, found nothing else, and reported the import missing -- with no trace
between the loadorder lookup and the failure, because nothing was ever opened.

Set to `b`. Wine's d3d9 on wined3d reaches the screen here through winevulkan
and RADV, and `graphics =` turned out to be a catalog label only
(`wine64_main.c:662`), not something that selects a backend. Real DXVK is the
better answer for a game this heavy and is worth installing, but it is a
download and a separate change.

### d3d9=b got the loader all the way through (2026-10-08)

With Wine's own d3d9 allowed, **every import resolved**: zero load failures, 52
modules, and the run reached t=10.4 s instead of 5.9. The loader is no longer
the problem -- GTA IV's own code runs.

What it ends on now is a fault inside a syscall, not a missing DLL:

    trace:seh:handle_syscall_fault code=c0000005 addr=8000e1eca ip=8000e1eca
      rax=0000002000000002 rcx=0000000058585858
    err:seh:handle_syscall_fault syscall fault 0xc0000005 at 8000e1eca
    trace:seh:handle_syscall_fault returning to user mode ip=00006fffffe448a4
    ...
    err:wow:log_reset syscall 0x43 came back replaced (2): status 0,
      eax 0x43 -> 0, eip 0x7bf2d6a0 -> 0x7bf2e5f6

`rcx` holding `0x58585858` is a poison pattern, and the address is in a PRX
below ntdll's `0x800830000`, so it is unix-side code reached from the 32-bit
side. Wine caught it, handed `STATUS_ACCESS_VIOLATION` back to the game, and the
game unwound through its own handlers. Resolving it needs the module base:
offset `0xe1eca` lands plausibly in win32u, winevulkan or opengl32 and guessing
between them is not worth a launch -- `pw_wine_dl_addr` is exported from ntdll
and `handle_syscall_fault` can name the module itself.

### DXVK, actually installed this time

DXVK 3.1.1 from the upstream release tarball (sha256 `40565b4a...e608`), x32 ->
`syswow64`, x64 -> `system32`, for d3d9, d3d11, d3d10core and dxgi. Verified as
genuine by their imports: no `wined3d.dll`, and the UCRT apisets instead.
Wine's originals are kept at `.wine-d3d-backup/` inside the prefix.

Two things made it safe to go straight to `d3d9=n`:

* the console reports `api 1.3.359`, so DXVK 3.x's Vulkan 1.3 floor is met;
* the `api-ms-win-crt-*` imports need no files -- Wine resolves them through its
  own API set map (`loader.c:get_apiset_entry`) -- and `setupapi.dll` and
  `vulkan-1.dll` are both already in the prefix.

### The syscall fault, located (2026-10-08)

Four diagnostics, each answering the next question, took it from a bare address
to a named call chain:

    syscall fault 0xc0000005 at libSceLibcInternal.sprx+0x51eca, address 2202daf860
    syscall fault in syscall 0x147a (win32u #1146), return ip 6fffffe448a4
    syscall fault called from libkernel.sprx+0x32aef
    syscall fault called from win32u.prx+0x242393   -> NtUserCreateWindowStation+0xc3
    syscall fault called from ntdll.prx+0xb58b2     -> stat_resolved+0x52

win32u #1146 is `NtUserInitializeClientPfnArrays`, which USER32 calls during
PROCESS_ATTACH. It runs `init_user()`, and the FreeType message appears directly
before the fault because `gdi_init()` -> `font_init()` prints it, so the fault is
in what follows -- `winstation_init()`, which is `NtUserCreateWindowStation`.

Three steps were needed to get there and each is worth keeping:

* **dladdr names only our own modules.** It is `pw_wine_dl`, which knows what it
  opened or adopted, so a fault in Sony's code printed a bare address. The
  kernel knows every module; `sceKernelGetModuleInfo` over
  `sceKernelGetModuleList` names any of them.
* **The module is not the call.** Every Wine path ends in libc eventually, so
  `syscall_id` was needed to say which syscall was running -- its low bits index
  the table, bit 12 picks win32u's over ntdll's.
* **One module can bury the frame that matters.** The first stack walk capped at
  three frames and spent all three inside libkernel -- `pthread_once`, which is
  how `init_user` is entered. Reporting a module once and staying quiet until it
  changes brought the Wine frames up.

### What it points at, and the guard

`stat_resolved` hands `r->full` to Sony's `stat`, which reads a path with no
bound. Every such buffer is a `char[PW_CWD_PATH_MAX]` inside `struct resolved`,
so reading that far is always in bounds -- what is not guaranteed is that
anything wrote a terminator, and an unterminated buffer walks off the end of the
mapping and faults inside libc, where it reads as a crash in a syscall rather
than as a bad argument in our own code.

`real_stat_full` and `real_lstat_full` now check for a terminator first and
refuse with EINVAL, saying so once. ⚠ This is a hypothesis with a guard on it,
not a diagnosis: the stack walk is a scan for code-shaped values, not an unwind,
so `stat_resolved` may be a stale slot. If the guard never fires, the fault is
elsewhere and the walk misled -- which the next run settles either way.

### Fonts are absent, and the FreeType build is dead weight

Separately, and not the cause of this crash: `init_freetype()` reaches FreeType
only through `dlopen(SONAME_LIBFREETYPE)`, and there is no `.so` on this console,
so it fails and fonts are unavailable. `build_wine_ps5.sh` builds
`libfreetype.a` and passes it as `FREETYPE_LIBS`, but it is **not on win32u's
link line** -- only Wine's own `freetype.o` is. The build step produces a library
nothing links and nothing can reach.

## The unixlibs were freeing ntdll's memory with libc's free (2026-10-08)

The guard on unterminated paths never fired, which killed that hypothesis and
also showed why it was wrong: the ntdll frame in the stack walk moved between
runs (`0xb58b2` then `0x239400`), so `stat_resolved` had been a stale slot. The
walk scans for code-shaped values; it does not unwind. What stayed put across
every run was `win32u.prx+0x242393`, and a return address is the instruction
after a call, so the disassembly settles it outright:

    24238e:  e8 cd a7 01 00   call 25cb60 <free@plt>
    242393:  48 89 d8         mov %rbx,%rax        <- the faulting return address

`NtUserCreateWindowStation` calls `free()`, and free faults inside Sony's libc.
The function is eight lines long and says the rest:

    wine_server_alloc_object_attributes( attr, &objattr, &len );   /* ntdll */
    SERVER_START_REQ( create_winstation ) ... SERVER_END_REQ;
    free( objattr );                                               /* win32u */

`wine_server_alloc_object_attributes` lives in ntdll and allocates from
`pw_wine_heap`. `free` in win32u bound to the **shared libc**, which had never
issued that block, and walked into it.

### Why the binding was wrong

`pw_wine_heap_libc.c` describes the arrangement that was supposed to hold:

> ntdll.so links this file and exports it, so win32u.so binds its malloc family
> to the same heap; the in-process wineserver links its own copy.

On PS4 that export never happens. `scripts/prx-ps4.sh` says so at the top --
exports come from the generated PRXDESC1 descriptor, **not** from the .so's
dynamic symbol table -- and the descriptor lists `pw_wine_heap_malloc` and
`pw_wine_heap_free`, not `malloc` and `free`. ntdll.shared.elf defines both as
`T` symbols and exports neither, so every other unixlib kept importing them from
libc. Measured before the fix:

    win32u.shared.elf:  U calloc  U free  U malloc  U realloc,  none defined

Adding the libc names to the descriptor does not work: the generator emits
`extern char malloc[];`, which is a redefinition as a different kind of symbol
against the real prototypes. Linking `pw_wine_heap.o` into each module would
work for the link and be wrong at runtime -- one heap per module, and this bug
is precisely a block crossing a module boundary.

What does work is the forwarding half alone. Every unixlib but ntdll and
wineserver now links `pw_wine_heap_libc.o`, so the libc names resolve locally
and the `pw_wine_heap_*` entry points they call resolve to ntdll: one heap, as
intended. `pw_wine_heap_calloc`, `_realloc` and `_memalign` joined the export
list, being pw_-prefixed and safe to declare. Verified after:

    win32u  libc-imports=0  defines=4  heap-imports=2
    win32u's free:  jmp pw_wine_heap_free@plt

### The shape of this one

This is the third heap-boundary bug in a day, and the third time the answer was
a sentence already written in the tree. The server had the same asymmetry, found
the same way. Worth asking of any new module: **which allocator does it bind,
and who allocated what it frees?**

### One heap fixed the syscall fault; the next one is graphics (2026-10-08)

Routing every unixlib's malloc family to ntdll's heap removed the syscall fault
entirely -- **zero** this run, against one on every previous run -- and the run
reached t=11.75 s. What ends it now is a different exception, and this one is
the game's own:

    err:d3d:wined3d_adapter_gl_init Failed to get a GL context for adapter 00AE4BD0.
    err:wow:raise_guest_exception guest exception 0xc0000005 at eip 0x79b1d308
                                  esp 0x21fe64 address 0x2c write 0

`0x79b1d308` lands between `1911.dll` at `79AE0000` (2,485,760 bytes, so it
spans to `79D3F800`) and `uxtheme` at `79D90000`: offset `0x3D308` inside
**1911.dll**, the Razor crack. Its imports say why it is in the graphics path at
all --

    d3d12.dll  dcomp.dll  dxgi.dll  MSVCP140.dll  VCRUNTIME140.dll  WINMM.dll

-- so the chain is 1911.dll -> Wine's builtin dxgi/d3d12 -> wined3d ->
`wined3d_adapter_gl_init`, which wants an OpenGL context this console does not
provide. wined3d returns nothing, and 1911.dll dereferences it at `+0x2c`
without checking.

Note what is *not* wrong: DXVK loaded and is in use for d3d9
(`d3d9.dll at 7ACE0000: native`). This is the **builtin** d3d stack, pulled in
behind it by the crack's own imports.

wined3d has a Vulkan backend; it only tried GL because `renderer` defaults to
AUTO (`wined3d_main.c:132`, selected at `:459`). `WINE_D3D_CONFIG=renderer=vulkan`
is the environment route, but the profile only emits a fixed set of variables
(`pw_game_runtime_env`), so the registry is the place:
`HKCU\Software\Wine\Direct3D`, `"renderer"="vulkan"`, written into the prefix's
`user.reg` (original kept as `user.reg.bak-pre-renderer`).

That is preferred over forcing `dxgi=n` to DXVK's: DXVK has no d3d12, so Wine's
builtin d3d12 would still come back to wined3d and still want GL. Setting the
renderer fixes the whole builtin stack at once.

### Fonts: three gaps between a built library and a glyph (2026-10-08)

With the Vulkan driver loading, GTA IV reached its own error dialog -- the
first frames this port has ever put on screen, `frames_put=3 shown=1
last=218x152` after an entire session at zero. The box was blank. Not a
rendering fault: there were no fonts, and three separate things had to be true
before there could be.

**1. FreeType was built and went nowhere.** `build_wine_ps5.sh` compiles
`libfreetype.a` and passes it to configure as `FREETYPE_LIBS`, but win32u's
`freetype.c` reaches FreeType only through `dlopen(SONAME_LIBFREETYPE)` and
`dlsym`, and the archive is not on win32u's link line at all. Every run since
the beginning reported

    Wine cannot find the FreeType font library.

`scripts/freetype-prx-ps4.sh` puts the archive behind a PRXDESC1 descriptor, as
`radv-prx-ps4.sh` does for the driver. The entry points are read from
`freetype.c`'s own `LOAD_FUNCPTR` lines rather than a list kept in the script --
all 31 verified present in the archive -- so a name added upstream cannot
quietly become a NULL pointer at run time.

⚠ The `FT_*` symbols come out `t`, not `T`, which looks like a failed export and
is not one: a PRXDESC entry stores the address, so local binding is irrelevant.

**2. The prefix had no fonts.** `drive_c/windows/Fonts` was empty, so a working
FreeType would still have had nothing to open. Wine's build ships six TTFs;
they are now in the prefix.

**3. The registry pointed at this machine.** With both of those done the message
changed, which is how the third showed itself:

    font:select_font can't find a single appropriate font - bailing

Both hives registered every font by its **host build path through the Z: drive**:

    "Tahoma (TrueType)"="Z:\home\zpeirce\ps4-gladius\prospero-win\.deps\
                         wine-host\install\usr\share\wine\fonts\tahoma.ttf"

which is where the files sat when the prefix was created here, and nowhere at
all on the console. 18 entries across `user.reg` and `system.reg`, rewritten to
`C:\windows\Fonts\`.

⚠ Worth remembering for any prefix built on the host: **`wineboot` records
absolute host paths**, and they survive the push. Fonts are the instance found;
anything else registered by path has the same problem waiting.

### ⚠ The font repoint hangs the 64-bit loader (2026-10-08, unresolved)

Repointing the font registry from host `Z:` paths to `C:\windows\Fonts` made
Wine open the TTFs for the first time -- and hangs it. Two runs in a row stop
at the same place:

    [247 t=1.339] WINE 0024:trace:module:LdrGetDllHandleEx L"ntdll.dll" -> ...

right after `wow64win`'s PROCESS_ATTACH, before the 32-bit exe loads, then
100+ seconds of nothing but native alive ticks and 160 s of CPU burnt.

The server trace says what it is doing: `REQ_select`, over and over.

    run -5:     1    run -4:     5    run -3:     1
    run -2:     6    run -1:  2728   <- the repointed registry

and the fourteen requests before the storm are two
`create_file`/`get_handle_fd`/`close_handle` triples -- font files being opened,
which had never happened before.

**But it is not the font loading.** `+font` was enabled and produces **not one
line**, so `font_init` is never reached; the hang is earlier, in the 64-bit
loader. The registry edit itself is clean -- diffing both hives against their
backups shows exactly the 18 intended value lines and nothing else -- so this is
not a malformed file.

What that leaves is the registry being *read*: the server loads `system.reg`
(3.2 MB) at startup, and a changed file may be normalised and written back
(patch 0150 exists because saving needs chunking). A save loop would look
exactly like this -- selects, CPU, no Wine output.

Both hives restored to their backups to isolate it; the attempt is kept as
`*.fontpaths-attempt`. ⚠ Not a fix, and fonts remain absent.

### ⚠ Never push the host's system.reg to the console (2026-10-08)

Nine runs were spent on a hang that one of my own pushes caused.
`tools/pw_prefix.py` rewrites the WoW64 CPU backend **as it pushes**:

    PC_CPU, CONSOLE_CPU = b'@="wow64cpu.dll"', b'@="wowprospero.dll"'

so the host's `system.reg` keeps the PC form and only the console's copy names
the DBT. Pushing the host copy -- for any reason, including restoring a backup
taken from it -- silently reverts `[Software\Microsoft\Wow64\x86]` to
`wow64cpu.dll`, which cannot work here. The process then hangs where the 32-bit
backend is entered, immediately after `wow64win`'s PROCESS_ATTACH.

The tell was in the loaded-module list the whole time:

    working:  wow64.dll  wowprospero.dll  win32u.dll  wow64win.dll
    hanging:  wow64.dll  wow64cpu.dll     win32u.dll  wow64win.dll

**Why it took nine runs.** The hang arrived with two changes at once -- the font
repoint and `libfreetype.prx` entering the package -- and I checked neither
against the last working log properly. Reverting the registry could not help,
because the backup was taken from the host and carried the same `wow64cpu.dll`.
Everything after that was chasing a self-inflicted fault: the console was
rebooted, `.wineserver` was moved aside, `libfreetype.prx` was removed, and a
real `st_dev` bug was fixed (patch 0877, correct on its own terms and worth
keeping) -- none of which could have mattered.

**The rule.** The host prefix and the console prefix are not the same artifact.
Anything pushed into `/data/prospero-win/prefixes/` has to carry the console
form of every value `pw_prefix.py` rewrites, or go through that tool. For a
single value the substitution is one line; what is never safe is copying a hive
across wholesale.

The last working log would have said so in one grep. `loaddll` names the CPU
backend on every run.

### The dialog could be read, and it asked for a soundcard (2026-10-08)

With fonts working the error box finally said what it wanted:

    GTA IV requires a soundcard in order to run

Not a crash and not graphics -- the game ran its startup checks, found no audio
endpoint, and said so. The cause had been in every log of the day, misread as a
printer driver:

    pw_wine_dl: cannot open .../wineps5.so ... not found
    err:mmdevapi:init_driver ...

`wineps5` is the audio driver. Patch 0120 already points
`HKCU\Software\Wine\Drivers\Audio` at "ps5", so Wine asks for it on every run;
upstream's `build_wine_ps5.sh` builds it from `wine/wineps5/unix.c` and
`src/pw_audio_mix.c` and finishes with ps5-native-tool. `scripts/prx-ps4.sh`
builds nine modules and this was never one of them.
`scripts/wineps5-prx-ps4.sh` is the PS4 arm, with upstream's compile flags and
export list verbatim.

### ⚠ PW_PRX_LINK, and three modules that were quietly wrong

Building it surfaced a mistake in all three PRXs added today.
`src/toolchain/prospero-clang:108`:

    if [ -n "${PW_PRX_LINK:-}" ]; then SHIMLIB=""; ... else SHIMLIB="$PWSHIM"; fi

`libwineshim.a` carries this port's stand-ins for the `wine/ps5` units, and
`prx-ps4.sh` sets `PW_PRX_LINK=1` so it stays off the line. My scripts did not
set it, so the archive answered `pw_wine_heap_malloc` and `pw_wine_dl_open`
out of its own members -- each module getting a private heap and a private
module registry instead of ntdll's.

For the heap that is a leak across the boundary rather than corruption
(`pw_wine_heap` counts a foreign pointer and returns). For the registry it is
fatal and silent: the driver looks its endpoint up by name --

    dlsym(RTLD_DEFAULT, "pw_wine_audio_available")
    dlsym(RTLD_DEFAULT, "pw_wine_audio_output")

-- ntdll exports both, but a private registry has nothing registered in it, so
`dlsym` answers NULL, the driver reports itself unavailable, and the game says
it has no soundcard. The same symptom we started from, reached by a different
route, and it would have looked like the fix simply not working.

`nm` tells them apart in one line: **`U pw_wine_dl_open` is right, `t` is not.**
Worth running against any new module here.

### The audio driver landed, and DXVK named the next wall (2026-10-08)

`wineps5.prx` cleared the soundcard check: no `mmdevapi:init_driver` failure,
the run went from ~4,400 records to 6,758, 56 modules, 18 seconds, and a clean
`PROCESS_DETACH`. GTA IV got far enough to write
`…\Rockstar Games\GTA IV\Settings\SETTINGS.CFG`, which is ordinary startup.

Then it printed three short strings and called `raise(22)` -- SIGABRT. The
writes went to `NtDeviceIoControlFile (10, …, 0x00504000, …)`, a console ioctl,
so the message went to a console with no conhost behind it.

It was in the log all along, untagged. Wine's raw stderr reaches the session log
as `WINE <text>` with no channel prefix -- the same way "Wine cannot find the
FreeType font library" did -- so **DXVK's entire log is already there**, and
grepping for lines without a `trace:`/`err:`/`warn:` prefix pulls it straight
out:

    info:  DXVK: v3.1.1
    info:  Game: GTAIV.exe
    info:  Vulkan: Found vkGetInstanceProcAddr in winevulkan.dll @ 0x7932d6d0
    info:  Enabled instance extensions:
    info:    VK_KHR_get_surface_capabilities2
    info:    VK_KHR_surface
    info:    VK_KHR_surface_maintenance1
    info:    VK_KHR_win32_surface
    err:   DxvkInstance::createInstance: Failed to create Vulkan instance

So the stack is all present -- DXVK loads, finds winevulkan, winevulkan has
libvulkan.prx -- and `vkCreateInstance` is refused.

All four extension names are present as strings in the RADV module, so it is not
a missing name. `VK_KHR_win32_surface` is winevulkan's own, and `ps5drv.c:853`
maps it to **`VK_KHR_display`**, creating surfaces from display planes
(`ps5_vulkan_surface_create`, which fails with "no host display (%u found)").
Whether this Mesa advertises `VK_KHR_display` at instance level is the open
question; `radv_CreateDisplayPlaneSurfaceKHR` exists, but the entry point
existing is not the same as the extension being enumerated.

⚠ Worth remembering for any future "the game printed something we cannot see":
**grep the session log for `WINE ` lines with no channel prefix.** Every
library that writes to stdout -- DXVK here, FreeType's warning earlier -- lands
there already.

## GTA IV reaches shader compilation (2026-10-08)

Three blockers fell in sequence and the game is now inside RADV compiling its
own shaders.

**1. The surface extension.** `ps5drv` mapped `VK_KHR_win32_surface` to
`VK_KHR_display`, which this console's RADV does not offer -- it offers
`VK_EXT_headless_surface`, which is what the bundle's triangle uses. The host
instance therefore got no surface extension at all, every surface entry point
was unresolved, and `vkCreateInstance` failed (patch 0878). After it:

    info:  Found device: PS5 (radv 26.2.99)

DXVK enumerating the PS4's GPU through our own driver.

**2. `dxgi=n` was wrong.** 1911.dll, the crack, imports `d3d12.dll` and
`dcomp.dll` -- Wine's own -- and those ask the adapter for Wine's **private**
DXGI interface, `17399d75-964e-4c03-99f8-9d4fd196dd62`
(`include/wine/winedxgi.idl:83`). DXVK's dxgi cannot answer it, so overriding
dxgi to native put DXVK underneath Wine's d3d12 and the query returned nothing;
1911.dll dereferenced it at `+0x2c`. That crash had been read as a DRM problem
through several runs. With dxgi left builtin the queries and the crash both
disappear. ⚠ DXVK's d3d9 is standalone: **override d3d9 alone**.

The DXVK version was never the variable -- 2.2 and 3.1.1 both reached the same
instruction, 2.2 only getting as far as enumerating memory types first.

**3. ACO faults on thread-local storage.** Now that pipelines are being built:

    err:vulkan:vkCreateComputePipelines Exception 0xc0000005 in Unix call.
    syscall fault 0xc0000005 at libvulkan.so+0x12f0f29, address 1120
      -> aco_compile_shader + 0x2e9

RADV imports `__tls_get_addr`, and this console answers general-dynamic TLS with
NULL -- measured earlier and recorded above, which is why wowprospero is built
`-femulated-tls` with its own `__emutls_get_address` (`src/native/pw_emutls_ps4.c`).
ACO uses `thread_local`; the NULL comes back and a field at offset 0x1120 is
read from it, which is the faulting address exactly.

The precedent says what the fix looks like, and the awkwardness is that RADV is
a prebuilt archive: either rebuild Mesa with `-femulated-tls`, or give the
module a `__tls_get_addr` that works, since the one it links now returns NULL.

## GTA IV reaches a swapchain, and the screen goes black (2026-10-08)

Three stubs in a row, each one hiding the next.

**1. dcomp (patch 0879).** `DCompositionCreateDevice` returned `E_NOTIMPL`
and never wrote `*device`; 1911.dll does not check the HRESULT and read a
field at `+0x2c` off the NULL it was left with. That is the `+0x2c` crash
that had been read as a DRM check, as a DXGI problem and as a DXVK version
problem over most of a day. A device object that answers `E_NOTIMPL` from
every method, but exists, ends it.

**2. dxgi (patch 0860).** The next line was
`dxgi_factory_CreateSwapChainForComposition ... stub!`, then thirty seconds
of nothing on a full core, `frames_put=0 vk_shown=0`. A composition
swapchain is one with no window; on this console that costs nothing,
because `ps5drv` returns a headless surface for any HWND. Make a hidden
`WS_POPUP` window and forward to the `ForHwnd` path.

**3. win32u (patch 0861).** Now `d3d12_swapchain_init` runs, the Win32
surface is created, and the title hands the display to Vulkan --
`PW_WINE64 display released to vulkan close=state shown=0`, which is the
black screen, not a failure. Then `vkCreateSwapchainKHR` -> `-3`
(`VK_ERROR_INITIALIZATION_FAILED`) and the whole stack unwinds, leaving
nobody owning the screen.

`adjust_surface_capabilities` overwrites the host's image extents with the
window's client rect. Correct where a window system exists; here the
surface *is* the display, and RADV's WSI scans it out through
`sceVideoOutRegisterBuffers`, which has buffers at the video mode's size
and no other. Leave the host extents alone under `__PROSPERO__`.

⚠ What the log does **not** say is which field RADV objected to: its stderr
goes nowhere from inside a PRX. 0861 therefore logs the eleven fields of
the request and the capabilities they were built from whenever the host
refuses a swapchain. Check that before measuring anything else.

⚠ Two process traps, both paid for today:

  - The patch series is `0100-0899` and `0870-0899` is contiguous. A new
    patch goes in the free `0821-0869` range. `build_wine_ps5.sh` refuses a
    duplicate or out-of-range number, and refuses it *after* resetting the
    tree.
  - `scripts/prx-ps4.sh` empties `prx/sce_module` and rebuilds only its own
    nine modules. `libvulkan`, `libfreetype` and `wineps5` have to be
    rebuilt after every run of it, or the package ships 50 MB light with no
    Vulkan driver in it.

⚠ `dxgi` and `dcomp` are PE modules and come from the **host** Wine build
(`.deps/wine-host`), not the ps5 one. Patching the ps5 tree alone changes
nothing on the console; the rebuilt DLL has to be stripped and copied into
`install/usr/lib/wine/{i386,x86_64}-windows/` for both architectures.

## The bug that was under everything: threads (2026-10-08, evening)

GTA IV's black screen was never graphics. The renderer was finished hours
before the cause was found, and the cause was that **no thread this port
created had ever run**.

### The chain, top to bottom

GTAIV.exe stops at `0x1211d82`. The disassembly says what it wants: it
queries its sound buffer for `{b0210783-89cd-11d0-af08-00a0c925cd16}` =
`IID_IDirectSoundNotify`, calls `SetNotificationPositions(2)` (vtable+0x0C),
`Lock` (+0x2C), `Unlock` (+0x4C), `Play(0,0,DSBPLAY_LOOPING)` (+0x30), and
waits on two handles, `bWaitAll` FALSE, INFINITE. Under that:

    winmm:waveOutOpen (..., 4294967295 = WAVE_MAPPER, ...)
    winmm:WINMM_StartDevicesThread Starting up devices thread
    sync:NtWaitForMultipleObjects type 1, handles {f4, f8}, (infinite)

`dlls/winmm/waveform.c:2377` line for line: an event, a thread,
`events[1] = the thread handle`, wait for either. The thread never signals
and never dies, because the server kills it:

    wineserver: protocol error 0028: read: Bad file descriptor
    wineserver: kill_thread 0028 exit=1 violent=1 from fatal_protocol_error+0xcf

### The bug

`create_server_thread` makes the request pipe, hands the read end to the
server with `wine_server_send_fd`, names it in `new_thread`, and closes it.
Correct where `SCM_RIGHTS` duplicated it into the receiver. **Nothing is
duplicated here** -- `dup` is EPERM for every kind of descriptor on this
console (`src/dup-probe`), so `wine_server_send_fd` passes the descriptor's
*number* and the in-process server, sharing this descriptor table, reads
that very fd. Closing it shut the pipe the server reads requests from, so
the server got EBADF on the first request and killed the thread.

⚠ The same hazard was already guarded twice, with the reasoning written out
both times -- `server_init_thread`'s close of the reply pipe, and the
server's own close of this pipe's other end. **This was the third and it was
missed.** When a port changes descriptor ownership, every `close()` after a
handover is a candidate; grep them all at once.

Patch 0866. After it: eighteen threads complete `init_thread` in a run,
reach `BTCpuThreadInit`, enter `BTCpuSimulate`, run guest code, winmm comes
up, `waveOutOpen` returns, and the alive tick reads **audio=1027** where it
had read audio=0 since the port began.

### ⚠ fprintf(stderr) reaches nothing, and has never reached anything

Zero `wine-ps5:` lines exist in any session log, ever -- including this
port's own: 0870's fd-release switch report, the `WINE_PS5_WAIT_WATCHDOG`
banner, and the slow-thread-start warning written for exactly the situation
above. The sink ntdll installs takes Wine's *debug* output, not libc's
stderr. **Use ERR() in ntdll** (it arrives even from a thread with no TEB)
and **sceKernelDebugOutText in wineserver** (klog, as `kill_thread` and
`pw_init_thread_note` already do). A diagnostic nobody receives costs more
than no diagnostic, because it reads as evidence of absence.

⚠ And keep the klog receiver alive. `pw_init_thread_note` had been naming
the exact failure all day into a channel that stopped recording when the
console rebooted.

### Where it stands now

`pthread_create` refuses at about a dozen threads with `-2147352541` =
`0x80020023` = `0x8002_0000 | 0x23` = **EAGAIN**, a resource ceiling, not a
heap -- though `spawn_thread` maps every failure onto `STATUS_NO_MEMORY`,
which sent this the wrong way for a while (0867 keeps the real number).

`src/thread-probe` (GLDS10009, `scripts/build.sh threadprobe`) asks which
resource: Wine's exact attributes, then a smaller stack, the library's own
stack, process scope, and a repeat after the first threads are joined --
separating a per-thread cost from a concurrent-thread ceiling. Built, not
yet run.

### Two traps paid for today

⚠ `build-app-ps4.sh` defaults to **NEO=0**. Every package built with just
`--pkg` runs a PS4 Pro as a base PS4, and the only sign is
`adapter_vk_init_driver_info ... device "PS5" 1002:9920` in the log. Always
`--pkg --neo`.

⚠ A patch regenerated with `git diff` against the **fully applied** tree
carries context from patches later in the series, and then will not apply
at its own position. 0867 was written against context that 0882 adds. Either
place the patch after the one that owns that code, or fold it in -- the NULL
`thread_data` guard went into 0882, which introduces the thread that has no
Wine data.


## 0015 hardware follow-up: the 16 MiB regions did not shrink (2026-10-09)

Two launches, at 08:38 and 08:42, reproduce spinning dots followed by a black
screen. The user confirmed the uploaded package was installed. Both runs
refuse thread 0080 at 19 threads with pthread_create=0x80020023, flexible
memory at 3072K, and the 256 KiB stack retry also refused. The large anonymous
regions remain 16384K. Audio progresses (1143 and 1106 respectively), but
vk_shown remains zero.

The local wowprospero.shared.elf disassembly of pw_wow_thread_budget contains
0x800000 for secondary arenas and 0x8000000 for the first arena. Its PRX
and the packaged sce_module/wowprospero.prx have identical SHA-256 hashes.
This verifies the local packaged budget; it does not independently hash the
installed console copy. The original attribution of the 16 MiB regions to
DBT arenas is unsupported by this experiment. Do not move executable memory
on that inference.

0016 records flexible memory before and after thread-state allocation, then
actual cache, code-arena and hostexec addresses and sizes, plus the selected
budget. The tracked emulated-TLS helper records flexible memory around
posix_memalign as well. These diagnostics go through pw_wow_log to
/data/prospero-win/logs/wowprospero.log; their hardware result is pending.

Capture all three channels before launching: scripts/logs.sh klog (TCP 3232),
scripts/ps5logd.py (TCP 9300, used by this package's dev.conf), and
scripts/logs.sh (UDP 18194, used by the native probes). TCP 9300 was already
held by an existing receiver writing ps5log-20261007-152429.log; its old
filename does not mean it stopped recording. Never start a second klog
receiver. Avoid FTP service probes: fetch known paths directly with ftp-get.py,
which does not attempt anonymous login.

The user proposed a smaller Windows game as a baseline before returning to
GTA IV, whose launch additionally involves 1911.dll and DirectComposition
compatibility patches. That baseline title is not selected yet.

0016 build validation: the full Wine build reports ntdll built=True despite
its known nonzero exit; PRX, RADV, FreeType, wineps5 and app builds completed.
The resulting 421 MiB package contains twelve modules and SFO ATTRIBUTE
0x00800000 (Neo). Packaged wowprospero.prx matches the rebuilt PRX, and its
ELF contains the new diagnostic strings. The helper compiles with warnings
as errors; the patch reverses cleanly and git diff --check passes.


### GTA IV profile comparison (2026-10-09)

The upstream prospero-win-profiles gtaiv.profile specifies video-memory
options, 1920x1080 fullscreen launch arguments, an explicit 1920x1080 desktop,
and XInput. The installed hand-written profile omitted arguments, display
and input sections; runtime logs confirmed desktop=default. Its d3d9-only
native override is deliberate for this copy's 1911.dll D3D12/DirectComposition
path, which needs Wine's private DXGI interfaces. Upstream's broader native
overrides and DXVK 2.6.2 are not equivalent to this prefix's DXVK 3.1.1.

Saved the original to build-ps4-logs/gtaiv-installed-20261009.profile and
created src/profiles/gtaiv.profile with upstream arguments/display and explicit
XInput while retaining d3d9=n and the existing diagnostic channels. The real
profile parser accepts it, and the launcher splits its arguments into 13 words.
A direct request for the game's commandline.txt returned FTP 550 (unavailable);
this does not establish whether that file is absent or inaccessible.


## The 16 MiB regions are explained by the SDK stack floor (2026-10-09)

At 08:52 the corrected profile loaded (desktop=1920x1080, arguments=13),
but GTA IV again went from spinning dots to black. This run also used 0016:
actual secondary arenas are 8388608 bytes at 0x100f160000 and similar high
addresses; cache entries and hostexec are in the same Wine-managed range.
Flexible memory generally does not fall across DBT setup. It does fall in
16 MiB steps as host threads are created, reaching zero; thread 007c fails
at 18 threads, including the small-stack retry.

ntdll.shared.elf defines pthread_create from the SDK compatibility archive.
Its disassembly resolves the stack floor from stackOfSelf, compares the
requested size against it, and raises smaller requests. The corresponding
orbis_thread.cpp creates new attributes for a raised stack and copies detach
and guard settings, but never the supplied stack address. Wine's explicit
1 MiB stack is replaced by a library-allocated 16 MiB flexible stack.
That is why the bare probe's 146-thread result did not predict Wine's ceiling.
The linked SDK binary is older than the SDK source's environment-aware
resolveFloor: do not assume setting ORBIS_THREAD_STACK will fix that binary.

Added src/native/pw_pthread_stack_ps4.c and linked it into ntdll with
--wrap=pthread_create. Explicit supplied stacks go directly to scePthreadCreate;
calls without a supplied address retain the compatibility wrapper. Wine
installs its own alternate signal stack in ntdll/unix/server.c:init_thread_pipe.
The helper reports supplied and actual stack address/size, creation status
and query status. Kernel error codes are returned unchanged.

A host check with real pthread workers and mocked console entry points
confirmed the supplied 1 MiB stack was actually used, creation errors
propagated, and the default path retained. PS4 compilation with warnings
as errors passes. Linked ntdll disassembly confirms spawn_thread calls
__wrap_pthread_create and the supplied-stack path calls scePthreadCreate.
Hardware confirmation of recovered flexible memory is still pending.


### Supplied stacks confirmed live; next baseline is Pinball (2026-10-09)

At 09:00 GTA IV uses the wrapper: requested and actual stack addresses
match, both 1024K, with create=0 and query=0. Flexible memory stays at
290816K, rather than falling to 0-3072K. This confirms the stack fix on
hardware. The guest now fails at vkd3d:d3d12_heap_init (vkMapMemory returns
-1), followed by a failed map_ptr assertion and a guest access violation
0xc0000005 at 0x7b9268e1, writing address zero. No frame or audio is produced
before this failure. The user reports the application closes without a host
crash. The D3D12 path belongs to this copy's 1911.dll startup; its relationship
to the failure needs further investigation.

Pinball at $GAME_SOURCE/games/pinball is the next authorized target. Its 32-bit
PE is fixed at 0x1000000, clear of the runtime, and imports GDI/User32/WinMM
and other basic Windows DLLs, with no Direct3D imports. src/profiles/pinball.profile
selects GDI and explicitly selects cpu=translator, avoiding the PS5-native
CPU default. Its separate prefix was initialized with the pinned host Wine
as user prospero and staged under build/pinball-console-prefix. Font registry
paths are repointed to C:\windows\Fonts, fonts are copied into the prefix,
the WoW64 CPU key selects wowprospero.dll, and symlinks become .pw-symlinks
tables using upstream pw_prefix.py's local_tree and to_console helpers.

Do not use upstream pw_prefix.py's FTP transport directly with GoldHEN: it
calls login(), SELF, CWD and MLSD. scripts/ftp-put-tree.py uploads the staged
tree with one connection, without login/probes/listing/deletion.

Pinball upload completed: 1884 files / 296275 KiB, all transfers confirmed.
The profile was uploaded last so the launcher cannot offer a partial prefix.
Validation confirmed game-file hashes, the translator registry entry, drive
link tables, portable font paths, and profile parsing. Hardware launch is pending.

Pinball launched on 2026-10-09 at 09:07 with GDI output and audible WinMM:
frames_put=13524, shown=1255, inputs=20, refused=0, audio=1233,
audible=1219. User reports symbol-like (Wingdings) text and controls do not
respond. Accepted native input packets are not proof of Windows key delivery.
The staged prefix initially copied six TTFs but omitted the installed Wine
bitmap fonts referenced by its registry, including MS Sans Serif and System.
Uploaded all 50 installed .fon files (471 KiB) to the prefix without login or
probes. Updated Pinball profile to trace font, keyboard, key and ps5drv instead
of the very noisy winmm channel. Text correction and key dispatch still need
verification on the next launch. Profile mappings: Options=F2 (new game),
Cross=Space (launch ball), L1=Z, R1=Slash (flippers).

### Pinball input pipe and bitmap font fixes prepared (2026-10-09)

The 09:12 launch registers only Marlett, Symbol, Webdings and Wingdings;
System selection falls back to charset=2 / cp=42. All .fon attempts fail
FT_New_Face with error 1. Tahoma on the console matches the staged SHA256,
so its absence is not a truncated FTP upload. Path-resolution trace is added
for the next run; the reason outline fonts are absent is still open.

0821-win32u-ps4-font-memory-face.patch selects FT_New_Memory_Face for already
mapped font bytes on this platform. FreeType's own fopen cannot traverse the
emulated dosdevices links. The metadata face is closed before those bytes
are unmapped; copied font metadata survives. Local FreeType checks parse
System, MS Sans Serif (three faces), and Tahoma from these exact files.

Native inputs increase (20 to 28) while no key mapping/dispatch appears.
server/queue.c:set_queue_fd still calls dup on the shared input pipe, and
closing its temporary file handle also closes the original descriptor on
this shared-table port. Patch 0869 uses borrowed poll fd objects retaining
the source file owner, with one persistent input handle in the PS5 driver.
Borrowed fd teardown removes its poll registration and releases its owner
without closing the shared native descriptor. Allocation failure also leaves
the borrowed descriptor open. Each UI thread retains its own poll object.
The existing unconditional drain would block after its first read because
PS4 refuses nonblocking mode; it now checks poll before each read, matching
inprocess_wake_poll_event. Key injection logs hwnd, VK, scan, down and status.
A real blocking-pipe check drains its bytes and returns without hanging.

The user clarified the application is running but its initial window frame
is gone. Both launches report 606x467 output; no persisted fullscreen setting
was found in the current Pinball user registry. Set profile display.view to
desktop to show the surrounding 800x600 desktop rather than crop to the game.
This is a presentation check, not proof of a fullscreen mode change.

Validation: a fresh archive of the pinned Wine base accepts all 124 patches
sequentially; the five changed source files exactly match the built tree.
Win32u and server compile/link with the updated sources; the PRX chain restores
RADV, FreeType and wineps5 after prx-ps4.sh. Hardware validation is pending.

Uploaded the rebuilt 441974784-byte Neo package to /data/pkg/wine-app.pkg
at approximately 09:26; FTP confirmed 226. Packaged win32u, wineserver,
ntdll and FreeType byte-for-byte match their rebuilt PRXs. The updated
Pinball profile is uploaded separately. Install this package before testing;
source fixes are not present in the previously installed title.

### Pinball controls confirmed on hardware (2026-10-09, 09:36 launch)

User installed the 09:26 package and confirms controls work. Runtime traces
show both down/up delivery with status=0 to hwnd=10046: F2 VK71 scan3c,
Space VK20 scan39, Z VK5a scan2c, Slash VKbf scan35. UI threads 0024 and 002c
both register queue fd=74 successfully. Patch 0869 is hardware-confirmed.

Font list now includes Courier, Fixedsys, MS Sans Serif (13/16/20 pixels),
Small Fonts and System (16 pixels), alongside the four symbol families.
System selects charset=0 / cp=1252 rather than charset=2 / cp=42. Patch 0821
fixes bitmap metadata loading on hardware; no Tahoma appears in resolution
traces, so its absence is still open. Do not conflate font enumeration with
user confirmation of all rendered text.

User clarifies repeatedly: game itself renders, window decorations are absent.
Full desktop presentation is active, with last=800x600; at 09:38:21 there are
70336 submitted frames, 5442 shown, 70 inputs/refused=0, audio9272/audible8780.
Changing presentation crop did not restore decorations. Existing prefix
CaptionHeight=25 and MenuHeight=18 are sane. Driver default style masks leave
the outer window rectangle intact; no explicit client-only crop was found.
Next Pinball profile replaces verbose +font with +win and warn+font, retaining
key/ps5drv traces, to inspect window styles/rectangles and nonclient painting.
No further runtime rebuild or reinstall is required for this diagnostic profile.

User accepts Pinball's missing window decorations and requests returning to
GTA IV. Pinball controls are the confirmed working baseline. GTA IV profile
now explicitly selects cpu=translator, keeps its existing upstream arguments,
1920x1080 and d3d9=n override, and uses +tid,err+all,+loaddll,+seh,+thread to
capture its loader/exception path without the prior sync/server flood.
All three log receivers were verified ready. Next launch uses the already
installed 09:26 runtime; compare with the 09:00 vkd3d vkMapMemory=-1 failure
in the 1911.dll startup path before changing another component.

GTA IV 09:43 launch repeats vkd3d vkMapMemory=-1 then null write at
7b9268e1; no frames/audio and flexible_free=290816K. A preceding line identifies
why: win32u_vkMapMemory2KHR returns mapping 0x883320000, which does not fit a
32-bit pointer. Wine unmaps it and returns VK_ERROR_OUT_OF_HOST_MEMORY. This
is a pointer-width failure, not evidence that flexible memory is exhausted.
The no-DRM RADV CPU-map path returns the existing GPU-arena address; it cannot
honor arbitrary placed addresses. Wine's placed-map/external-host capability
selection needs inspecting before choosing a repair. Updated GTA IV profile
traces Vulkan and D3D12 instead of SEH/thread for the next launch.

09:51 GTA IV run with Vulkan tracing confirms the same failure and address
0x883320000. init_physical_device enumerates neither VK_EXT_map_memory_placed
nor VK_EXT_external_memory_host for the loaded PS4 driver. Wine therefore
uses ordinary CPU mapping, then rejects its high pointer for WoW64. More
unchanged launches will not resolve this; driver/bridge support for a low
32-bit CPU mapping is the next implementation requirement.

Important source distinction: scripts/radv-prx-ps4.sh links the prebuilt
sdk/orbis-sdk-v1/mesa/build-orbis/src/amd/vulkan/libvulkan_radeon.a. The full
source in mesa-build/mesa-ps4 gates placed mapping on KMS/DRM in
radv_physical_device.c; its no-DRM ac_orbis_drm CPU map rejects a fixed address different from the
existing GPU-arena mapping. It is not evidence that the currently packaged
SDK archive supports the feature, and enabling an extension alone is not a
correct repair. Do not truncate the pointer or treat VK_ERROR_OUT_OF_HOST_MEMORY
here as proof of memory exhaustion.

After the network interruption, UDP18194 and runtime TCP9300 remained alive
with fresh runtime data. Replaced only klog receiver PID790090 with PID902402,
exec session8937; connected and received buffered console output. New klog:
build-ps4-logs/ps4-klog-20261009-094758.log. Original klog remains preserved.

### Low-address direct-memory alias probe built (2026-10-09)

User authorized building the feasibility probe before the Mesa mapping change.
New standalone target mapprobe / GLDS10010 / Gladius Mapping Probe, source
src/map-probe/map_probe.c. Package path /data/pkg/mapprobe.pkg; does not modify
the installed Wine runtime or driver. Built with --neo and -Wall -Wextra -Werror;
entry point, process parameters and 16 KiB PT_LOAD alignment checks pass.

For each Onion(type0) and Garlic(type3) allocation, map 64 KiB with CPU/GPU RW
protection0x33 at a kernel-chosen address. Reserve a low address without
overwrite (fixed|no-overwrite) before mapping the SAME physical allocation
there. Candidates: 0x10000000, 0x20000000, 0x40000000, 0x60000000. Check writes
in both directions over every word, unmap the alias and verify the primary
mapping survives. Also test a one-page alias at physical offset+16 KiB for
suballocation support. Retain physical backing until title exit if mapped
memory cleanup fails. The title stays alive after DONE for normal shell close.

A host harness substitutes memfd-backed shared mmap for the console kernel
entry points: all 18 maps (two primaries, eight aliases, eight offset aliases)
pass with zero mismatches and both allocations release. Injected alias-map
refusal also cleans reservations and releases both primary allocations.
These checks validate probe logic, not PS4 kernel support. No GPU commands
are submitted; a GPU-copy probe must follow any successful kernel alias test.
Output uses klog and begins 'mapprobe: BEGIN'; inspect 'below4g=1',
'bidirectional ... mismatches=0', cleanup return codes and DONE.


### Kernel alias test passed; Mesa implementation built (2026-10-09 10:08 onward)

Hardware mapprobe passed both Onion and Garlic at all four low addresses:
0x10000000, 0x20000000, 0x40000000, 0x60000000. Full 64 KiB bidirectional
checks and physical+16 KiB page aliases had zero mismatches. All alias/primary
unmaps and direct-memory releases returned zero; the primary remained usable
after each alias unmap. Evidence: build-ps4-logs/ps4-klog-20261009-094758.log,
10:08:11 through mapprobe DONE at 10:08:11.822. This proves kernel feasibility,
not Vulkan GPU access.

Mesa now creates a separately owned placed CPU view of the BO's real backing:
Onion physical offset is arena_phys + GPU_VA - arena_map_base; Garlic uses its
own direct allocation and offset. Foreign/unmapped/misaligned buffers refuse
placed maps. Unmapping an alias leaves the GPU mapping intact; RESERVE restores
a no-overwrite virtual reservation. Aliases are also removed before backing
retirement/free. PS4 advertises VK_EXT_map_memory_placed only with this code.

Patches saved in src/mesa-patches-ps4/: 0001 preserves the existing Gladius
changes; 0002 adds CPU aliases. Base Mesa commit is
1a59cc147b54e3970814b37313e2f27357672e9d. Archive build passed (766 targets),
log build-ps4-logs/mesa-placed-local-build.log. Actual mapping functions also
passed host shared-memfd tests for Onion/Garlic, reserve/remap, map refusal,
unmap failure retention, reservation failure and invalid inputs; evidence
build-ps4-logs/mesa-alias-host-check.log.

New vkmapprobe / GLDS10011 / Gladius Vulkan Mapping Probe is uploaded to
/data/pkg/vkmapprobe.pkg. Built with --pkg --neo --dev-mesa and warnings as
errors. Tests every host-visible coherent memory type, low placed maps, a
GPU copy of 16384 words, RESERVE unmap, remap at the same address, a second
GPU copy, normal unmap and resource destruction. Hardware result pending.

radv-prx-ps4.sh accepts PW_RADV_MESA_SRC/PW_RADV_MESA_BUILD to select this
archive explicitly. Its default remains SDK Mesa pending the GPU-copy test.
Do not launch unchanged GTA IV expecting the new path: the installed Wine
package still has the original Vulkan PRX until a rebuilt package is installed.

Local RADV PRX build passed (24 MiB), log
build-ps4-logs/radv-placed-prx-build.log. A candidate Wine package also built
(442236928 bytes), but is not uploaded. Final source review added a null-BO
guard for VA-only unmaps; archive and PRX were rebuilt and host checks/reverse
patch verification passed again. Repackage Wine from that latest PRX before
uploading after the hardware test. No vkmapprobe START received yet.


### Vulkan low aliases passed first GPU checks (2026-10-09 10:22:10)

vkmapprobe hardware run: memory type2 (GTT, flags0x6) and type3 (visible VRAM,
flags0x7) both mapped 64 KiB buffers at 0x10000000/0x11000000 and copied
16384 words with zero mismatches, twice each, including RESERVE, remap and
normal cleanup. This validates Onion and Garlic through the actual Vulkan
mapping and GPU submission path. Evidence in current klog at 10:22:10.043.

The probe then incorrectly reported FAIL for type4: that is the VRAM
RADEON_FLAG_32BIT memory type excluded by this transfer buffer's
memoryTypeBits. This was a probe error, not a failed alias/copy. Corrected it
to destroy the incompatible buffer and SKIP the type, so cached type5 can
also be tested; uploaded revised /data/pkg/vkmapprobe.pkg. Awaiting rerun.

RADV PRX script now defaults to paired local Mesa; explicit
PW_RADV_MESA_SRC/PW_RADV_MESA_BUILD overrides remain available. Latest Wine
package rebuilt with the final PRX (442236928 bytes). Upload in progress.
The first corrected-probe upload authorization timed out; one retry succeeded.
No FTP probes or listings were performed.
Wine upload completed successfully: /data/pkg/wine-app.pkg, 442236928 bytes,
FTP226. User should rerun corrected mapping probe before installing/launching
Wine for GTA IV. Runtime driver change is not yet confirmed through WoW64.


### Vulkan mapping probe fully passed (2026-10-09 10:25:27)

Corrected hardware run ended `vkmapprobe: DONE tested=3 result=PASS`.
Type2 GTT (flags0x6), type3 visible VRAM (flags0x7), and type5 cached GTT
(flags0xe) each passed two GPU copies of 16384 words with zero mismatches,
placed CPU views at 0x10000000 and 0x11000000, RESERVE unmap, same-address
remap, normal unmap and resource cleanup. Type4/type6 RADEON_FLAG_32BIT GPU-VA
memory types were correctly skipped because transfer buffer memoryTypeBits
excludes them. Six copies verified 98304 words in total. Evidence:
build-ps4-logs/ps4-klog-20261009-094758.log, 10:25:15.448 START through
10:25:27.248 DONE. The 12-second startup completed without a probe failure.

Next: close probe, install /data/pkg/wine-app.pkg (already uploaded with the
new RADV PRX), launch GTA IV. Check extension enumeration for
VK_EXT_map_memory_placed and low WoW64 CPU maps; native probe success does
not yet prove Wine's integration or GTA IV rendering. Runtime listener9300,
klog3232 and UDP18194 remain required.


### First GTA IV run with placed mapping: progress, then map refusal (10:27)

Wine recognized placed mapping and successfully mapped at 0xd40000, created
D3D12 resources and submitted GPU work. At 10:27:31.850 a later map returned
VK_ERROR_MEMORY_MAP_FAILED (-5); vkd3d then asserted heap->map_ptr and the guest
faulted at 0x79f9bff6 writing NULL. No frames or audio; flexible free286720K.
This differs from the original high-pointer rejection: low aliases are active.
Evidence: build-ps4-logs/ps5log-20261007-152429.log, 10:27:18 launch onward.

Source review found a definite mapping bug: the new alias required BO size to
be a multiple of16 KiB, but RADV allocations can be4 KiB. GPU VA/backing already
rounds these to the kernel page; aliases now do the same. The exact size of the
failed GTA buffer was not printed, so hardware rerun must confirm causality.
Small-buffer actual-function host checks passed for Onion and Garlic, including
coherence, reserve/remap and failure cleanup; log
build-ps4-logs/mesa-alias-small-host-check.log. Archive and PRX rebuilt; patch0002
updated and reverse-apply check passed.

Expanded vkmapprobe now tests both64 KiB and4 KiB payloads for each compatible
memory type; allocationSize stays at the Vulkan requirement while low VA
reservations round to16 KiB. Uploaded /data/pkg/vkmapprobe.pkg and requested
hardware run. Wine package rebuild in progress; do not install the previously
uploaded Wine package expecting this size fix until replacement upload finishes.
User reported probe crashed on close after prior PASS; recorded but deferred
at their direction. Completed copy results precede that teardown crash.


### Small-buffer hardware validation passed (10:30:18.256)

Expanded vkmapprobe ended DONE tested=3 result=PASS. Both64 KiB and4 KiB
allocations on GTT, visible VRAM and cached GTT passed low placed maps, GPU
copies, reserve/remap and cleanup. Twelve GPU copies, zero mismatches
(104448 words total). This validates kernel-page rounding in the driver.
Wine packaging/upload remains next before repeating GTA IV. The failing GTA
buffer size was not logged, so do not claim the game is fixed before rerun.
Small-buffer Wine package upload completed: /data/pkg/wine-app.pkg,
442236928 bytes, FTP226. Console install and GTA IV rerun pending.


### GTA IV progressed beyond cracktro; shader compiler heap failure (10:32)

With small-BO page rounding, the previously failed mapping now succeeds at
0x39e0000; the Razor1911 cracktro runs (user confirmed), with GPU work and
audible audio. GTA IV then initializes native D3D9/DXVK but stalls during
shader compilation. Runtime reached frames_put6, audio2951/audible1656.

First faults at10:32:25.539: libvulkan.so+0x10b04ce writes address9 and
+0x10b07c1 writes address18. llvm-addr2line resolves them to
nir_alu_instr_create / nir_intrinsic_instr_create; disassembly shows a NULL
return from gc_zalloc_size being dereferenced. DXVK then reports
VK_ERROR_OUT_OF_HOST_MEMORY after Unix-call exceptions. The runtime still has
278528K flexible memory; Wine heap is25360K. These aren't proof of system
memory exhaustion. libvulkan.shared.elf still imported the malloc family
from libSceLibcInternal instead of Wine's heap (the earlier13 MiB libc trap).

RADV PRX now links pw_prx_heap_wrap_ps4.o and imports ntdll's
pw_wine_heap_malloc/calloc/realloc/free/memalign. Standard/aligned allocators,
strdup/strndup/asprintf/vasprintf all use this heap, keeping allocation/free
provenance consistent. Existing strdup(NULL) guard preserved. ntdll.prx is
NEEDED and those C libc allocation imports are absent from final ELF. PRX
build passed; host actual-wrapper tests passed formatting/truncation,
alignment validation, calloc/realloc and matching frees. Logs:
build-ps4-logs/radv-heap-prx-build.log and radv-heap-host-check.log.

Wine package build in progress. GTA IV rerun required to confirm this
allocator change fixes shader compilation. No hardware success claimed yet.
Final allocator review also found imported C++ delete/delete[]/sized-delete.
orbis-compat's local C++ new calls the now-wrapped malloc, so those three
deletes are wrapped to Wine heap free too. Disassembly confirmed new ->
__wrap_malloc; final ELF no longer imports C++ delete. PRX rebuilt and host
allocator tests passed again; Wine package rebuilding from this final PRX.
Final shader-heap Wine package built and uploaded successfully (10:37):
/data/pkg/wine-app.pkg, 442236928 bytes, FTP226. Host tests include all three
C++ deletes. Install/launch GTA IV pending; loggers left running.

### GTA IV reached the loaded scene (2026-10-09 10:39)

User confirmed “IT LOADED” after launching the heap-corrected Wine package.
The run passed the earlier crash site; no repeated NIR NULL write or DXVK
VK_ERROR_OUT_OF_HOST_MEMORY. New WoW64 placed maps include 0x1f450000 and
0x20450000. Swapchain reached1920x1080, frames_put rose to7, and runtime kept
alive through tick2520; logs continue GPU fence/command-pool activity. User has
not confirmed sound; audio callback counters alone are not proof of audible
output. `shown=0` in diagnostic counter, so visual confirmation comes from the
user, not that counter. This is a major milestone; assess controls, sound and
sustained gameplay with user feedback before claiming full compatibility.
Evidence: build-ps4-logs/ps5log-20261007-152429.log 10:38:43–10:39:32.

### App crash after loaded scene (2026-10-09 10:39:46)

The current GTA IV run stayed alive ~66 seconds after the user confirmed the
scene loaded. It submitted/presented Vulkan frames and did not repeat the
shader allocator failure. At10:39:46 thread00c4 faulted inside
libSceLibcInternal+0x51ef7 while executing win32u syscall NtUserCallNoParam
(0x133c). Fault address reported as0x453a00af4017, followed by syscall and
thread teardown faults; the runtime disconnected10:39:51 and GoldHEN opened
its crash reporter. No cause is proven: faulting code is Sony libc and the
syscall's subcode/registers were not logged. Before the fault, system flexible
memory remained235520K and RADV used Wine heap peak63472K, so the prior shader
allocation failure did not recur. Capture for next iteration: log syscall
argument/code and x86_64 fault registers only on syscall faults, to avoid noisy
normal Vulkan traces; inspect NtUserCallNoParam code path before changing it.

### Audio confirmed audible on hardware (2026-10-09)

The user moved the console to a display with speakers and confirms sound
plays. Until now audio had only ever been inferred from counters, and the
record said so: *"audio callback counters alone are not proof of audible
output."* Now it is confirmed, and the counters are vindicated as a proxy --
GTA IV's last run read `audio=7710 audible=3501`, and `audible` counts grains
containing non-zero samples, about 45% of them, which is what music and engine
sound with gaps between should look like.

⚠ The earlier silence was the display, not the runtime. Audio leaves this
console over HDMI and follows the screen, and a display change can leave
**Settings → Sound and Screen → Audio Output Settings** pointed at the previous
device -- which from the logs is indistinguishable from a broken audio path,
because the port opens and the grains flow either way (`PW_WINE64 audio sink=1
port=536870919 status=ok`). Check the console's output device before reading
silence as a bug.

So the runtime now has, on hardware and user-confirmed: a rendered display
(Pinball GDI, and GTA IV reaching a loaded scene), working controls, and
audible sound.

## The pad reader was missing from the package (2026-10-09)

GTA IV's controls did nothing, and it was not the mapping. Tracing the input
channels instead of guessing:

    trace:xinput:XInputGetState index 0, state 0021F994.
    trace:xinput:find_title_pad no Unix library, status 0xc0000135:
        HID controllers

The game polls XInput tens of thousands of times and is told there is nothing
there. `0xc0000135` is `STATUS_DLL_NOT_FOUND`: every xinput PE asks for patch
0470's reader by one exact name --

    UNICODE_STRING name = RTL_CONSTANT_STRING(L"xinput1_3");

-- and `xinput1_3.prx` was never in the package. xinput's Unix library is the
only one with no `.so` of its own, so `tools/build_wine_ps5.sh` compiles it
directly; this arm's `prx-ps4.sh` builds its nine modules from their `.so`
files and never replicated that step. xinput fell back to enumerating HID
controllers, of which this console has none.

Built and shipped: thirteen modules instead of twelve, and the log now reads
`find_title_pad controller 0 is the title's`.

⚠ Two things checked rather than assumed, each of which would have been a
wasted fix:

  - GTA IV loads `xinput9_1_0.dll`, which the ps5 tree does not build. Its
    `main.c` `LoadLibraryExW`s `xinput1_4.dll` and forwards, and the log
    confirms `xinput1_4` loading right after -- the patched xinput was in play
    the whole time.
  - A USB keyboard is not an option on this console, and the title says so:
    *"hid: no PS4 implementation, continuing without keyboard or mouse."*
    `pw_hid_ps5.c` loads a PS5 sysmodule by id and there is no PS4 arm. The pad
    is the only input there is.

### And the next wall is the GPU

With input working the game runs for about ninety-five seconds -- polling
XInput 66228 times and DirectInput 68298, audio audible throughout -- and then:

    WINE err: DxvkSubmissionQueue: Command submission failed: VK_ERROR_DEVICE_LOST

Not a CPU fault: zero `handle_syscall_fault` in the whole run. The console
agrees it is the GPU and handles it as such -- a coredump, then
`EXEC /system/sys/gpudump.elf`, then `getGpuCrashFullDumpAppStatus` and the
crash reporter. The title is killed by the system, not by a fault in our code.

⚠ It has happened before: there is an earlier `gpudump.elf` in the same klog at
11:18, from a previous run. So device loss is not new with the input fix.

⚠ klog does not carry the reason. It shows Sony's crash *handling* only; the
fault detail goes into the GPU dump. Nothing in the serial log says which
submission killed it.

State at the loss: `dmem=1521184K` (1.45 GiB direct memory), `flexible_free=
206848K`, `heap=86384K`, `frames_put=7`, `vk_shown=0`. The profile passes
`-availablevidmem 1536`.

Open, and unprioritised: whether the loss is time- or event-dependent (does a
second run die at the same point?), whether lowering the game's video-memory
argument or resolution changes it, and whether RADV's hang detection can be
reached on this console given that the environment is not published to it.

### The GPU loss is deterministic, at the cutscene (2026-10-09)

Two Neo runs, both dying at the same place: through the loading screen, through
"loading first mission", and then at the moment the intro cutscene would start
rendering. The user's observation, not the log's -- `vk_shown=0` means the
title's counters never see RADV's own presents, so what is on screen is only
knowable from the room.

So it is event-driven, not time- or leak-driven: a render path that appears for
the first time at that moment takes the GPU down.

The two deaths differ in severity, which is itself information:

    run 1  11:38:03  DxvkSubmissionQueue: Command submission failed:
                     VK_ERROR_DEVICE_LOST        (then ran on briefly)
    run 2  11:45:35  alive tick=11220, then --- disconnected ---
                     (no DXVK error at all)

Run 2's kill arrived faster than DXVK could report it. Audio was healthy to the
last tick in both (`audible=19665`).

⚠ Correction to an earlier reading in this file: **every run today reports
`1002:9924`, Gladius.** The `1002:9920` seen previously was from before the
`--neo` fix. The Pro path has been active for all of today's work, including
the runs that loaded a scene with working sound and input -- so Gladius is not
newly implicated by this crash, it has simply never been exercised this far.

### The base-PS4 experiment, set up but not yet answered

A package built without `--neo` runs the Pro as a base PS4: 18 CUs, Liverpool.
The point is to switch off the path README calls *"written and unexercised"* --
`CHIP_GLADIUS` is declared and every captured dump, CTS run and frame in
mesa-ps4's record came off a base PS4.

    renders the cutscene  -> the fault is in the Gladius path
    dies the same way     -> Neo is not the variable, and the cutscene's own
                             shaders are next, on any CU count

Status: the control is confirmed good -- the run reports `1002:9920`, so the
Neo bit really is off -- and it was healthy at 2m40s, past where the Neo runs
were by then. But it was closed before the cutscene, so **it proves nothing
yet**. The Neo package is kept so the pair can be compared properly.

⚠ Do not read "survived longer" as a result. The Neo runs died at the
cutscene, not at a time, so only reaching the same point counts.

## The GPU's own account of the hang, and why we nearly read it wrong (2026-10-09)

The RADV env loader paid off: with `MESA_LOG_FILE` pointing at
`/data/prospero-win/logs/radv.log`, `ORBIS_DUMP_HUNG` finally wrote somewhere
readable, and a Neo run produced the first hang dump this project has ever had.

### Two hangs, and the dump covers the wrong one

    line  210   submit #4997 - label stuck at 4996 for 4 submissions. DUMPED.
    ...         the run continues for ~14,300 more submissions, 6528 frames
    line  578   fence slot 10 still owed to submission 19323 after 5 s. NO DUMP.

**#4997 recovered.** The log runs on past it for thousands of submissions with
working scan-out (`ZERO COPY`, 1920x1080, 3 us copies). The hang that actually
killed the process is **#19323**, and it produced no stream at all -- only the
five numbers in that error line.

Two separate reasons, both in the instrumentation rather than the driver:

* The submit-path detector held `static bool reported` as a **process-wide
  one-shot**. #4997 tripped it, and the latch stayed thrown for the rest of the
  run. Every later hang, including the fatal one, was silently skipped.
* The fatal hang does not go through the submit-path detector at all. That check
  runs *on the way in to a submit*, so it only fires while submissions keep
  arriving -- it goes quiet exactly when the GPU stops for good. #19323 was
  caught in the fence-slot wait, which printed numbers and returned `-ETIME`.

Both fixed in `src/mesa-patches-ps4/0003-orbis-dump-the-hang-that-kills.patch`:
the detector re-arms whenever the fence label moves again (capped at
`ORBIS_HUNG_DUMP_MAX` dumps), and the fence-slot wait now runs the same dump on
`label + 1` before it gives up.

### ⚠ The dump's own conclusion was wrong, and it was stated as fact

The #4997 dump printed, in capitals:

    submit #4997 compute user data at the stop: 0x8327c000 0x80000008
                 0x88720000 0x00000008 0xfffc0000 0x00000ff0
    submit #4997 its buffer 0x888720000 + 4294705152 bytes lives in BO 24's
                 mapping 0x885c00000..0x889c00000
                 - THE WRITE RUNS PAST THE END OF THE MAPPING

That reads as a 4 GiB fill running off a 64 MiB buffer, and it is wrong. The
block assumes the stopped dispatch is RADV's `fill_memory` meta, whose push
constants are `{uint64 addr; uint32 max_offset; uint32 data}` -- so slot 4 is a
length. **Every compute pipeline writes the same `COMPUTE_USER_DATA` registers**,
so that reading is a guess, and here it did not survive its own stream: the
`DISPATCH_DIRECT` a few dwords later is

    c0031502 000000c0 00000001 00000001 00000045    -> 192 x 1 x 1 groups

`fill_memory` launches `ceil(size/16)` threads in groups of 64, so 192 groups is
at most **192 KiB** -- which fits inside BO 24 with ~21 MiB to spare. The grid
and the "length" disagree by four orders of magnitude, which means the push
constants are not a fill's and there is no overrun to explain.

Patch 0003 also rewrites that block to print the mapping, the launched grid and
the assumption as three separate facts, instead of announcing a conclusion drawn
from one number that may not mean what it is being read to mean.

### What was ruled out along the way

* `radv_init_dcc()` (`radv_cmd_buffer.c:15962`) is the one metadata path with a
  subtraction that can underflow (`meta_size - size`), and it is the obvious
  Neo-shaped suspect. It is gated on `gfx_level == GFX8` and does not run under
  the current Orbis setup: `ac_drm_query_hw_ip_info()` hardcodes GFX IP version
  7.2 in both modes, so RADV selects enum `GFX7` (ordinal 9). This is the
  driver's chosen generation, not proof that Gladius lacks Polaris-era
  features. Neo changes topology in this winsys, while gfx level is currently
  forced to the Liverpool-compatible path.
* `ac_surface.c` and the RADV sources contain **no** `CHIP_GLADIUS` or
  `CHIP_LIVERPOOL` arms at all -- surface layout goes through the generic GFX7
  addrlib paths, parameterised by `info`. So a Gladius surface bug would have to
  come from wrong topology *input*, not from a Gladius-specific code path.

### Still open

The Neo-vs-base-PS4 result stands: the same code without `--neo` gets through
the cutscene. But the mechanism is **not** identified -- the one dump we have
describes a hang that recovered, and its headline conclusion does not hold up.
The next Neo run is the first that can dump #19323 itself.

Two leads in the same log that are still unadjudicated:

    RESIDUE GREW across devices - 49 BO(s) was 43, 32 syncobj(s) was 28,
    49 VA range(s) was 43 - something is leaking per device

    radv/orbis: offchip stride 32768 B, 256 buffer(s) allocated,
    4 shader engine(s); VGT_HS_OFFCHIP_PARAM <- 0x00000100

The second is the `ORBIS_HS_OFFCHIP_PER_SE` question: `ac_gpu_info.c` states that
these parts read `OFFCHIP_BUFFERING` **per shader engine**, and 256 programmed
across 4 engines implies 1024 buffers against 256 allocated. GTA IV is 2008-era
D3D9 through DXVK and almost certainly never tessellates, so a mis-sized tess
ring would be allocated and never written -- which is why this stays a lead and
not a hypothesis.

## The Pro raster-config override reached the preamble, but did not prevent the cutscene crash (2026-10-09)

The first 0004 run was invalid: the captured command stream still wrote
`0x2a00161a`. A diagnostic-only follow-up, `0005-raster-config-path-diagnostics.patch`,
was built into a Neo package and deployed. The console's `radv.env` explicitly
contained both overrides before launch. Its `radv.log` confirmed:

    raster config calculated family=57 pci=0x9924 gfx=9 max_se=4 rb_mask=0xff max_rb=8
      -> 0x3a00161a/0x0000002e (override=0x3a00161a/0x0000002e)
    raster config preamble path=direct family=57 rb_mask=0xff max_rb=8
      -> 0x3a00161a/0x0000002e
    c0026900 000000d4 3a00161a 0000002e

So the override is active, and `ac_cmdbuf.c` takes the direct path; the harvested
path and a later value overwrite are ruled out for this run. The user reported
the same crash at the intro cutscene. The latest runtime stream disconnected at
13:58:45 after `PW_WINE64 alive tick=10800`; it contained no
`VK_ERROR_DEVICE_LOST`. The local klog receiver captured no crash reason.
`radv.log` recorded GPU stalls at submissions `#5023`, `#5039`, `#13099`, and
`#17416`. The final snapshot is in
`build-ps4-logs/radv-final-20261009-1358.log` (ignored by git).

Conclusion: the four-SE raster-config change was genuinely tested and did not
fix the Neo hang. Do not repeat it as an untested hypothesis. A direct
`SQ_WAVE_HW_ID` measurement has since been taken; it reports 4 SE x 1 SH x 9
active CU IDs, with the same CU bitmap on each SE. This resolves the silicon
topology question; an independent second launch reproduced the same masks. It
does not change the raster-config negative result.

### Hardware-ID topology probe prepared and uploaded (2026-10-09)

The older `GLDS10002` probe reported Vulkan shader-core properties from RADV;
it did not read the physical GPU topology. Its Neo run reported 4 SE x 9 CU =
36 CUs, while its FMA throughput result was about 1.9 TFLOP/s. Neither alone
settles whether all Pro CUs are enabled.

The new `0006-probe-sq-wave-hw-id.patch` adds an opt-in compiler hook used only
by the probe process. `gl_SubgroupID` in its compute shader is mapped to
`s_getreg_b32` for `SQ_WAVE_HW_ID`; the shader atomically sets a bitmap bit for
each observed `(SE_ID, SH_ID, CU_ID)`. The native probe decodes and prints the
four bitmap words and a CU mask for each SE/SH pair. SPIR-V inspection confirmed
`SubgroupId` survives as a built-in at local size 256, the RADV lowering point
was identified, and the modified RADV archive compiled successfully.

The first six Neo runs returned only `bitmap[0]=0x00000001` and were invalid.
The shader dump showed that `nir_opt_uub` folded the values derived from
`load_subgroup_id` to zero, even while the intrinsic remained textually in NIR.
A probe-only bypass for UUB preserved the use chain. The successful run's ACO
output contains `s_getreg_b32 imm:-2044` (the `SQ_WAVE_HW_ID` selector); its
bitmap is `0x000003ef` for each of SE0 through SE3, with SH1 empty. That is nine
active CU IDs per SE (0-3, 5-9), 36 observed pairs total. This is the first
direct silicon topology result, reproduced by a second independent app launch.
The raster-config change remains a separate tested negative result.

## Two-SE Mesa topology and raster A/B still hangs at the same draw (2026-10-09)

After the measured-CU-mask A/B also failed, a no-rebuild run set
`ORBIS_NUM_SE=2` and the matching two-SE raster pair
`0x2a00161a/0x00000000` in `/data/prospero-win/radv.env`. The retrieved RADV log
confirms this reached initialization, raster preamble, tess-ring sizing, and
the fatal command stream. Mesa reported `SE=2`, 18 CUs, and used the two-SE
raster pair. This changes Mesa's topology inputs; it does not physically
disable two of the four shader engines measured by `SQ_WAVE_HW_ID`.

The run still failed at the same indexed draw. Submit #21317 was 1448 dwords;
the CP reached dword 1220 and execution retired through 1080. The last
`DRAW_INDEX_2` was at dword 1097, with 4770 indices from a mapped allocation
bounded at 6144; the captured UINT16 values were 0-915. Runtime logging showed
`VK_ERROR_DEVICE_LOST` at 17:09:06 and disconnected ten seconds later. See
`build-ps4-logs/radv-20261009-two-se-run.log`.

Together with the 4-SE control and sparse-CU-enable B run, this rules out the
tested Mesa SE-count/raster settings and explicit sparse CU-enable mask as
standalone fixes. The same draw and CP/EOP positions recur across all three.
The failure remains in or after that draw, but the logs do not yet identify
which shader stage or hardware wave is stuck.

The follow-up run set `ORBIS_FORCE_NEO=0`, removing the experimental SE and
raster overrides while keeping the same Pro hardware and Neo-built package.
RADV confirmed base mode (`device_id=0x9920`, Liverpool, 2 SE, 18 CUs, CU masks
`0x1ff`, raster pair `0x2a00161a/0x00000000`). This is a software-personality
test, not base-PS4 silicon. It still failed at submit #18834, the same 1448
dword stream, CP dword 1220 / retired dword 1080, and indexed draw at dword
1097. Runtime reported `VK_ERROR_DEVICE_LOST` at 17:13:31. See
`build-ps4-logs/radv-20261009-force-base-run.log`.

The fatal stream contains `PKT3_INDEX_TYPE` (`opcode 0x2a`) with value zero
before the draw. On this GFX7 packet path that selects `VGT_INDEX_16`, resolving
the earlier ambiguity: the actual indices range 0-915, within the 6144-index
allocation bound. The first 128 dwords of the draw's pixel shader and resolved
main VS are identical in the four-SE control, two-SE Neo, and forced-base
captures. The available evidence now points inside draw execution or its
vertex/texture data accesses rather than to a 32-bit index interpretation or
shader-code variation between these RADV identities.

Across the four-SE Neo control, sparse-CU B run, two-SE Neo run, and forced-base
run, Mesa topology and raster settings changed but the failure stayed at the
same draw. Stop treating CU count, mask, SE count, raster pair, or the Mesa
device identity as standalone explanations. The remaining diagnostic gap is
the active hardware wave state at the draw: the existing dumps capture shader
programs and CP/EOP progress, but not a stuck wave's PC/status. The standard
RADV MMIO read callback is explicitly refused by `ac_drm_read_mm_registers`,
so its normal hang-register dump cannot fill this gap without a separate
hardware-readable path.

## Forced-base run reproduced the same hang; fatal-only descriptor walk staged (2026-10-09)

The app ran again with `ORBIS_FORCE_NEO=0` on the same PS4 Pro and the same
Neo-built package. RADV selected Liverpool/base identity (device `0x9920`, 2 SE,
18 CUs, `0x1ff` CU masks) but the GPU still stopped at the same draw. Runtime
reported `VK_ERROR_DEVICE_LOST` at 17:22:50; klog recorded the HP3D watchdog at
17:22:53 and the app disconnected at 17:22:59. The fatal stream is submit
**#18663**, 1448 dwords, with CP progress at dword 1220, EOP retired through
1080, and `DRAW_INDEX_2` at dword 1097. It again uses 4770 UINT16 indices
(0-915) from a mapped BO with a 6144-index bound. See
`build-ps4-logs/radv-20261009-current-run.log` and the current runtime/klog
captures.

Patch **0015** adds `ORBIS_FOLLOW_HUNG=1`: after the existing fatal timeout
captures the retained stream and indexed draw, it follows user-data pointers
from that fatal stream only. This reuses the guarded live-mapping/freed-range
checks and avoids enabling `ORBIS_FOLLOW_SH` across every submission, which can
produce thousands of descriptor entries per frame. The patch reverse-applies
to the current Mesa tree and compiled successfully; the RADV archive, PRX, and
Neo package were rebuilt. The package was uploaded to `/data/pkg/wine-app.pkg`
and installed before the next launch. Its SHA-256 is
`42ed4d4286d175ec685066c2de8b37514a3bc18db6dc84a8336eb5f9df553858`.

The known `/data/prospero-win/radv.env` now retains the forced-base identity and
progress/EOP settings and adds `ORBIS_FOLLOW_HUNG=1`; a no-login FTP GET verified
the uploaded file at `build-ps4-logs/radv-20261009-follow-hung-verified.env`.
The next launch ran the fatal-only descriptor walk to classify user-data
pointers. It still does not read the GPU's stuck-wave PC/status.

## Fatal descriptor walk ran; freed-range warnings are address-reuse false positives (2026-10-09)

The new package was installed and reproduced the same hang. Runtime reported
`VK_ERROR_DEVICE_LOST` at 17:35:29 with `frames_put=7`, `shown=0`. Fatal submit
#18540 again stopped in the 1448-dword stream around the indexed draw at dword
1097. See `build-ps4-logs/radv-20261009-follow-hung-run.log` and
`build-ps4-logs/ps5log-20261009-111351.log`.

Do not treat 0015's `USE AFTER FREE` text as a confirmed lifetime bug. Its
graveyard records only old address ranges, not allocation generations or the
current owner. The scanner flagged SH `0x04e` at `0x883271a00`, yet the same
walk resolves that address to BO4's live main VS code; SH `0x240` resolves to
zeroed BO5, and SH `0x00c` to BO34. These establish address reuse and false
positives in the current classifier, while leaving open whether any submitted
pointer is stale. The other walked user-data buffers include BO59 (3296 KiB)
and BO63 (16 KiB), which carry descriptor-shaped data and are more promising
places to locate the actual faulting base.

At submit 18432 the one-shot scan found the exact address once, at BO34 offset
80. The surrounding words encode base `0xff0000000` and size `0x3fc00` (261120
bytes), matching the tessellation factor-ring descriptor RADV intentionally
builds in `radv_queue.c`. It is expected data, not an identified cause of the
draw hang. The scan took 17850 ms to read 253 MiB and skipped 227 MiB of the
480 MiB mapped, so it cannot establish uniqueness.

The same run then failed at submit #20653, again dword 1097, with CP progress
1220 / EOP 1080 and the in-bounds UINT16 index range 0-915. Runtime reported
`VK_ERROR_DEVICE_LOST` at 17:42:58 and disconnected at 17:43:07. Its fatal-only
walk again labels reused addresses as freed and identifies BO70 (16 KiB) and
BO89 (3296 KiB) among user-data buffers. The complete RADV capture is
`build-ps4-logs/radv-20261009-target-scan-final.log`.

The verified remote RADV environment now raises `ORBIS_SCAN_MAX_MIB` to 512
while retaining the one-shot exact scan at submit 18432. This should cover the
480 MiB mapped in the last run; estimated scan time is about 34 seconds.

The next launch stalled at submit #4948, before the scan trigger, so it yielded
no address-scan result. The runtime remained alive but stopped progressing the
present sink (`frames_put=7`, `shown=0`). The next-run RADV environment is now
verified with `ORBIS_SCAN_AT=4096` and the same 512 MiB cap, ahead of the
observed stall. Captures are `build-ps4-logs/radv-20261009-full-scan-progress.log`
and `build-ps4-logs/ps5log-20261009-111351.log`; verified env is
`build-ps4-logs/radv-20261009-scan-before-hang-verified.env`.

That next run completed the scan at #4096: it found only the known BO34 offset
80 factor-ring descriptor (`VA 0x8833ac050`), reading all 256 MiB mapped then
with no skipped BOs in 15744 ms. Later RADV warnings marked submits #9719 and
#12426 as stalled, then the fatal repeat at #18639. This was again the
1448-dword stream, CP progress 1220 / EOP 1080, with the same `DRAW_INDEX_2` at
dword 1097 and 4770 valid UINT16 indices (0-915). Runtime reported
`VK_ERROR_DEVICE_LOST` at 17:56:18 and disconnected at 17:56:26. See
`build-ps4-logs/radv-20261009-scan4096-progress.log`; klog independently
confirms the HP3D watchdog killed Shell UI at 17:56:22 in
`build-ps4-logs/ps4-klog-20261009-1730.log`.

The next-run environment has since been restored to `ORBIS_SCAN_AT=18432` and
`ORBIS_SCAN_MAX_MIB=512` to capture the larger late-run BO map shortly before
#18639. Verified copy: `build-ps4-logs/radv-20261009-full-scan-next-verified.env`.

The #18432 scan then read all 480 MiB mapped across 103 BOs in 34380 ms, with
no skipped BOs, and found only BO34 offset 80 (`VA 0x8833ac050`), the expected
factor-ring descriptor. The same fatal stream followed at submit #22591:
1448 dwords, CP 1220 / EOP 1080, indexed draw at dword 1097, 4770 UINT16 indices
0-915 within the 6144-index bound. Runtime reported device loss at 18:24:18;
klog recorded the HP3D watchdog killing Shell UI at 18:24:22 and the title crash
at 18:24:26. The complete RADV log is
`build-ps4-logs/radv-20261009-scan18432-progress.log`.

The current remote environment removes `ORBIS_SCAN_VA64` and `ORBIS_SCAN_AT`;
`ORBIS_FOLLOW_HUNG=1` and progress/EOP logging remain. This avoids repeating
the 34-second scan now that the complete late-run map contains only the
expected descriptor. Verified copy:
`build-ps4-logs/radv-20261009-hung-only-next-verified.env`.

With the scan disabled, the next launch again reached a persistent fence timeout
at submit #19844. Earlier 4-submission warnings (#4975, #8729, #13727, #13757)
recovered; #19844 remained owed and its wait dump points to the same indexed
draw at dword 1097 with 4770 in-bounds UINT16 indices. Runtime reported device
loss at 18:28:20, and klog recorded HP3D killing Shell UI at 18:28:23 followed
by the title crash at 18:28:27. This confirms the diagnostic scan was not the
cause. Capture: `build-ps4-logs/radv-20261009-hung-only-progress.log`.

The next launch again timed out at submit #18574, with the 1448-dword stream,
CP 1220 / EOP 1080, and indexed draw at dword 1097 (4770 UINT16 indices,
range 0-915, bound 6144). The CP address audit was clean (0/16 DMA_DATA
addresses unmapped). Runtime reported device loss at 18:33:31; klog recorded
the HP3D kill at 18:33:34 and crash report at 18:33:38. Capture:
`build-ps4-logs/radv-20261009-hung-only-progress.log`.
## 0019 reproduces hang; draw-bound sampled-image slot resolves outside VA (2026-10-09)

Patch 0019 reproduced the GPU hang at submit #18935. The final indexed draw
uses 2232 UINT16 indices (maximum 909) with a 4096-index bound. Its vertex
input descriptor at SH `0x04e` points to `0x88a296000`, stride 36, and 910
records; the base resolves inside live BO31 with ample remaining bytes. The
vertex access range therefore fits the observed indices.

The draw-bound pixel shader at `0x88cc7f400` loads eight dwords from
`s[2:3] + 0x18` and then executes `image_sample_lz`. SH `0x00e` is set to
`0x894600bc0`, while the shader prolog sets `s3=8`, making the actual load
address `0x894600bd8`. The fatal descriptor walk captured the loaded words as
`00000000 fffff1ff 00000000 00000000 00000000 00000000 00000000 00000000`.
The log's `gfx=9` is the raw enum ordinal, which means `GFX7` in this Mesa
tree. The base-address fields in `ac_set_mutable_tex_desc_fields()` use the
same encoding on both sides of the GFX9 split: word 0 carries `va >> 8`, and
word 1's high-address field carries `va >> 40`. On that basis these bytes
decode to `0xff0000000000`, outside the mapped VA window. This remains a
candidate, not a proven cause: its Vulkan binding is unknown and the title may
have submitted an unused or partially initialized descriptor.

An earlier reading attributed `0xc0046900/0x31f` from the PM4 stream to this
image descriptor and calculated an unmapped address `0x1fc004690000`. That was
incorrect: those words are in the command-stream dump. The actual shader load
from BO89 instead decodes to `0xff0000000000` using the common image-base
encoding. Do not
carry forward the earlier address. Also, the captured active-wave PS/VS snapshots differ
from the draw-bound pair, so they do not identify the exact faulting PC. The
next useful step is to trace the shader's descriptor slot through shader
metadata and RADV descriptor-set updates, then log the originating Vulkan
binding and descriptor contents at submit time. Do not mutate the descriptor
before identifying its owner. Full capture and analysis are in
`docs/HANDOFF-2026-10-09.md`, section “0019: check descriptor candidate bases
against live BOs”.

The same 0019 package was launched again with `ORBIS_FORCE_NEO=0` on the Pro.
It again used device ID `0x9920`, raw gfx enum=9 (`GFX7`) and 18 CUs, and hung
at submit #18677:
640 dwords, fence slot 4 owed after 500 ms, CP reached and retired through
dword 518. All three draw-shrink targets matched, yet the final draw was still
2232 indices at dword 370 (UINT16 maximum 909, bound 4096). The draw-bound
PS/VS addresses and code matched the previous run. SH `0x00e` moved to
`0x885600bc0`, while its data was byte-for-byte identical, including the
sampled-image words `00000000 fffff1ff` followed by six zeros. Under the
common image-base encoding the base is again `0xff0000000000`. This strengthens the invalid
descriptor lead, but the run does not prove the descriptor is consumed at the
faulting PC or identify its Vulkan binding. Full capture:
`build-ps4-logs/radv-20261009-repeat-final.log`. Runtime reported device loss at
20:54:00.986 and disconnected at 20:54:10.073; Shell resumed by 20:54:28 with
no full reboot or watchdog kill evident in klog.

## 2026-10-10 correction: PS scalar-load offsets map to three valid descriptor slots

The GFX9 `s_load_dwordx*` immediates in `submit-18935-draw-ps.disasm` are
DWORD offsets. Reading the image load at `0x18` as byte offset `+0x18` was
incorrect. Converting the three image/sampler pairs to bytes gives image
offsets `0x60`, `0`, and `0xc0`, and sampler offsets `0xb0`, `0x50`, and
`0x110`. These exactly match the captured set-0 layout: three 96-byte
combined-image-sampler descriptors at `0`, `0x60`, and `0xc0`, with each
sampler at byte `0x50` within its descriptor. Thus the earlier claimed
`0xff0000000000` image descriptor at the fatal draw was an artifact of the
offset-units mistake. The fatal dump did not include enough bytes to inspect
bindings 1 and 2. The next useful Mesa diagnostic is to dump all three full
descriptors at the fatal submission and correlate their contents with their
descriptor writes/copies. This settles resource validity without assuming an
offset-lowering bug.

## 2026-10-13: non-split Pinball run succeeds; split comparison is inconclusive

The non-split PS4 package rebuilt with the custom `pw_dso_handle_ps4.c`
relocation helper removed launched Pinball successfully. The live log reached
584 submitted 800x600 frames and 940 audible audio buffers. The package was
uploaded to `/data/pkg/wine-app.pkg` for installation. This confirms that the
custom relocation helper was not required for this working title.

The first split package (`wine-orbis`, built 18:21) omitted RADV's
`libvulkan.prx` from both runtime locations. The later `wine-orbis-with-mesa`
and `wine-orbis-allocator-fallback` packages include it, so that omission does
not explain the later no-frame run. The later split run reached
`wine startup: server connected` at 19:57:37.514, then its log disconnected
at 19:57:47.092 without any frame or audio. The successful non-split run did
not submit its first frame until about 12 seconds after `server connected`,
and then reached 584 submitted 800x600 frames and 940 audible buffers. The
split capture ended before that point, and the log does not say whether the
app crashed or was closed. It is therefore inconclusive about whether the
split package can render Pinball; repeat it and keep the run alive for at least
15–20 seconds after `server connected`.

The later split package has the same runtime paths as the working non-split
package but 1,623 differing file contents; notable differences include
`win32u.prx` (2,854,800 to 2,638,272 bytes), `winevulkan.dll` (both PE
architectures substantially larger), `wowprospero.dll` (45,056 to 139,746
bytes), and `eboot.bin` (715,408 to 683,264 bytes). These are comparison leads,
not identified causes. The working non-split package SHA-256 is
`89170ce06947e69e64af26a6c832b09f568191911399d70ac153379dbd43a5ff`.

## 2026-10-13: package assembly A/B and split build provenance

The known-good non-split payload was repackaged under the split app ID
`ORBW00001` as `/data/pkg/wine-orbis-baseline.pkg`. The staged package has the
same 1,783 files as the working package. Every file is byte-identical except
`sce_sys/param.sfo`, which has the new ID and title; the package size is also
identical at 443,088,896 bytes. The user installed and launched this package
and reported that it worked. The new ID and package builder can therefore
launch the known-good payload. This does not yet identify which rebuilt split
binary causes the other package's failure.

Two more packages isolate the changed executable from the changed Wine runtime:

| ID | Console package | Executable | Wine runtime |
| --- | --- | --- | --- |
| `ORBW00002` | `/data/pkg/wine-orbis-split-title.pkg` | split | known-good non-split |
| `ORBW00003` | `/data/pkg/wine-orbis-split-runtime.pkg` | known-good non-split | split `wine-orbis-allocator-fallback` |

Both were uploaded and their staged manifests checked against their source
packages: each has 1,783 files; only `eboot.bin` and `param.sfo` differ from
its runtime source. `ORBW00002` ran Pinball to at least 2,895 frame puts and
1,215 audible audio buffers. `ORBW00003` connected to wineserver but stopped
after eight sink calls, zero frames and zero audio. Its split `ntdll.prx`
reported `virtual_setup_exception stack overflow 384 bytes` and then aborted;
the PS4 recorded a SIGILL and coredump. The abort site is `abort_process` at
offset `0x99109` in the unstripped split NTDLL. This isolates the failure to
the split Wine runtime, though not yet to its PE DLLs or PRX modules.

`ORBW00004` (`/data/pkg/wine-orbis-split-prx.pkg`) combines the known-good
executable and PE DLLs with the split PRX modules. `ORBW00005`
(`/data/pkg/wine-orbis-split-pe.pkg`) combines the known-good executable and
PRX modules with the split PE DLLs. Both are uploaded for the next Pinball
hardware comparison. In the first `ORBW00004` run, Pinball stayed at spinning
dots for at least 30 seconds: 12 sink calls, zero frames and zero audio, with
the Wine process still alive. This implicates the split PRX side independently
of the split PE DLLs. In the first `ORBW00005` run, Pinball crashed about two
seconds after wineserver connection with the same `virtual_setup_exception`
stack-overflow diagnostic as `ORBW00003`; klog recorded SIGSYS and a coredump.
Thus the split PE files also fail against the known-good PRXs. The split Orbis
Wine configure command used `--without-freetype` and did not set the
FreeType/Vulkan library sonames. The working build has
`SONAME_LIBFREETYPE=libfreetype.so` and `SONAME_LIBVULKAN=libvulkan.so` in its
generated config, while the split build has neither. This is a concrete
configuration gap that can explain the PRX-only Pinball stall. The split
build script now requires a PS4 FreeType archive and configures both sonames;
the rebuilt config now defines both sonames. The resulting `win32u.prx` grew
from 2,638,272 to 2,854,832 bytes, within 32 bytes of the working build.
`ORBW00006` packages the rebuilt split PRXs with the known-good EBOOT, PE DLLs,
and FreeType PRX for a focused hardware test. Its local package is
`pkgout/orbis-freetype-prx/IV0000-ORBW00006_00-ORBW000060000000.pkg`; an
initial upload failed while the console was offline, then a direct FTP retry
succeeded at `/data/pkg/wine-orbis-freetype-prx.pkg`. The console installed and
ran it. Pinball startup was very slow: it showed one game frame after roughly
104 seconds, then reached 7,988 submitted frames, 1,049 displayed frames, and
1,331 audible buffers by roughly 136 seconds. The runtime eventually renders
at normal speed; the prolonged startup needs its own comparison. The split
port can also build
its own `libfreetype.prx` from the PS4 FreeType archive, but that new module is
held for a separate test. Separately, the
split launcher rejects the MDK profile because it does not recognize
`nglide_resolution = desktop`; that obsolete key has
been removed from the local MDK profile and uploaded to
`/data/prospero-win/profiles/mdk.profile`. The next launcher scan counted eight
games instead of seven and emitted no MDK refusal, confirming the parser fix.
It does not affect the Pinball comparison.

The console then reran `ORBW00004`, the split PRXs built without FreeType or
Vulkan configure sonames. Pinball also loaded: its first game frame appeared
after roughly 82 seconds, and by roughly 127 seconds it had submitted 5,294
frames, displayed 696, and produced 1,003 audible buffers. `ORBW00006` first
drew at roughly 85 seconds and similarly reached normal rendering speed.
Thus enabling FreeType and Vulkan in the PRX build did not change the slow
startup; the earlier observation of zero frames at 50 seconds was premature.

The split full-build driver had a separate stale-output risk: it skipped the
host Wine PE build whenever the build tool and install directory existed,
regardless of changes to `wine/orbis/base-patches` or Vulkan staging inputs.
The split checkout now calls the host builder on every full build; that builder
compares an input stamp and reuses the PE install only when it matches. The
first stamped rebuild was interrupted by the OS killing `cc1` during `mshtml`
with six compile jobs. A two-job continuation exposed another build-script bug:
Vulkan staging was applied again to already-staged source and failed its
single-match assertion. The script now records a source-stage stamp and only
restages after resetting the source when an input changes. The existing staged
tree was verified and stamped so `make` could resume incrementally with two
jobs. That rebuild exposed a missing `pw_vk_batch_allocator` definition in
the staged 32-bit Vulkan PE source; the generated classifier was restored and
the build resumed. The rebuilt host PE runtime completed with two jobs; its
hardware result remains pending. `ORBW00007`
packages only those PE files with the known-good EBOOT and PRXs; its local
package is `pkgout/orbis-rebuilt-pe/IV0000-ORBW00007_00-ORBW000070000000.pkg`
and was uploaded to `/data/pkg/wine-orbis-rebuilt-pe.pkg` for hardware testing.
`ORBW00008` combines that PE runtime with the rebuilt split PRXs and the new
split `libfreetype.prx`, keeping the known-good EBOOT and Mesa Vulkan PRX. Its
local package is
`pkgout/orbis-coherent-runtime/IV0000-ORBW00008_00-ORBW000080000000.pkg`
and it was uploaded to `/data/pkg/wine-orbis-full-runtime.pkg`. Both package
stages were checked against their intended source hashes. Test `ORBW00007`
first to isolate the PE result, then `ORBW00008`. Hardware proved both packages
invalid before Wine startup: `ORBW00007` and `ORBW00008` failed with
`PRX_SCE_MODULE_LOAD_ERROR` because the one-off package construction omitted
`sce_module/libc.prx` and `sce_module/libSceFios2.prx`. The normal split
`build_app_orbis.sh` already requires them; the ad hoc A/B packager did not.
Their invalid local package directories were later removed to free build space;
the hardware and packaging findings remain recorded here.
Corrected packages `ORBW00009` (PE only) and `ORBW00010` (full runtime) include
both byte-identical platform PRXs from the working package and were uploaded
to `/data/pkg/wine-orbis-pe-corrected.pkg` and
`/data/pkg/wine-orbis-full-corrected.pkg`. `ORBW00009` was launched: it
connected to wineserver, then logged `virtual_setup_exception stack overflow
384 bytes` about 1.5 seconds into game startup, followed by PS4 SIGSYS.
Rebuilding the host PE runtime did not cure the early failure. `ORBW00010`
was later tested and failed with the same stack-overflow diagnostic. The old split PE runtime
predates patch 0900, which only edits the server, so staleness
is a build-system fault rather than an established cause of the application
failure.

The imported patch `0900-server-log-pollfds-before-poll` writes a klog line
before every wineserver `poll()`. It was enabled in both `ORBW00004` and
`ORBW00006`, unlike the known-good base PRXs. Their klogs contain a flood of
those lines, making this a concrete candidate for the ~82–85-second startup
versus ~11 seconds in the known-good split-EBOOT/base-runtime control. The
klog contains 1,198 per-poll lines during `ORBW00006`'s first-frame interval
and 1,193 during `ORBW00004`'s corresponding interval. This is correlation,
not yet proof that the logging accounts for the delay. The
patch has been moved out of `wine/orbis/base-patches` into
`wine/orbis/diagnostic-patches`; its change was reverse-applied to the build
source, and the PRXs rebuilt successfully. Only `wineserver.prx` changed
relative to `ORBW00006` among the runtime PRXs, so a single-module package
can test the logging hypothesis directly. `ORBW00011` is that package:
`pkgout/orbis-no-poll-log/IV0000-ORBW00011_00-ORBW000110000000.pkg`, uploaded
to `/data/pkg/wine-orbis-no-poll-log.pkg`. Its payload was compared bytewise
against `ORBW00006`; only the two copies of `wineserver.prx` and package
metadata changed. On hardware, `ORBW00011` reached its first Pinball frame in
about 11 seconds and had audible buffers by about 13 seconds, matching the
known-good control. This confirms the per-poll wineserver logging caused the
82–85-second startup delay.
`ORBW00012` combines the corrected full runtime from `ORBW00010` with the
no-poll-log wineserver; it was built with the guarded A/B packager, which
verified 1,780 payload hashes, and uploaded to
`/data/pkg/wine-orbis-full-no-poll-log.pkg`. Its local package is
`pkgout/orbis-full-no-poll-log/IV0000-ORBW00012_00-ORBW000120000000.pkg`.
On hardware, `ORBW00012` connected to wineserver and logged the same
`virtual_setup_exception stack overflow 384 bytes` at 07:06:13.652, about
1.6 seconds after game boot. Klog identified SIGSYS and title `ORBW00012`.
`ORBW00010` also failed with the same stack-overflow diagnostic at
07:06:49.245, about 6.4 seconds after game boot; klog identified SIGILL and
title `ORBW00010`. The extra delay matches its per-poll logging overhead.
Thus the early failure remains with a coherent rebuilt PE and PRX runtime,
independent of the poll logger.

Two more guarded A/B packages use working `ORBW00011` as the base. `ORBW00013`
replaces only the i386 and x86_64 PE `ntdll.dll` files from the rebuilt host
runtime; it is uploaded as `/data/pkg/wine-orbis-ntdll-pe-only.pkg`.
`ORBW00014` replaces only x86_64 PE `wowprospero.dll`; it is uploaded as
`/data/pkg/wine-orbis-wow-pe-only.pkg`. Both stages passed full payload hash
verification. On hardware, `ORBW00013` reached at least 1,319 Pinball frame
puts and 1,219 audible buffers by about 20 seconds. `ORBW00014` reached at
least 523 frame puts and 801 audible buffers by about 18 seconds. Neither
isolated replacement reproduces the startup crash. `ORBW00015` combines those
three replacement DLLs in the working base package; its 1,781 payload files
passed hash verification and it was uploaded to
`/data/pkg/wine-orbis-ntdll-wow-pe.pkg`.
On hardware, `ORBW00015` ran Pinball with the three rebuilt PE modules
(`i386`/`x86_64` `ntdll.dll` and x86_64 `wowprospero.dll`) and the rest of the
working runtime. It reached 3,902 frame puts and 1,031 audible buffers by
07:21:33. These replacements work together when the known-good `wow64.dll`
remains installed, further isolating the `ORBW00018` failure to that DLL.

`ORBW00018` isolates the leading PE suspect. It uses the working `ORBW00011`
stage and replaces only `x86_64-windows/wow64.dll` with the rebuilt copy.
The stage verified 1,781 payload hashes and was uploaded to
`/data/pkg/wine-orbis-wow64-pe-only.pkg`. On hardware it connected to
wineserver at 07:17:56.008, then produced the exact familiar
`virtual_setup_exception stack overflow 384 bytes addr 0 stack 1000123e80`
at 07:17:57.074. Klog recorded SIGSYS and a coredump for `ORBW00018`. This
proves the rebuilt PE `wow64.dll` alone is sufficient to reproduce the early
failure, while rebuilt `ntdll.dll` and `wowprospero.dll` alone are not.
PE import-table inspection shows the working `wow64.dll` imports only
`ntdll.dll`; the rebuilt one also imports `kernel32.dll`. The extra import came
from patch `0613-wow64-import-kernel32-debug-helper.patch`, which changed
`dlls/wow64/Makefile.in` so calls to `debugstr_w()` in `dlls/wow64/syscall.c`
could link against `IsBadStringPtrW`. That patch is now replaced and renamed
to `0613-wow64-avoid-kernel32-debug-helper.patch`. It removes those debug
helper calls while retaining backend diagnostics with a numeric candidate
index. The rebuilt candidate `ORBW00019` imports only `ntdll.dll`, was packaged
from the working `ORBW00011` stage, passed all 1,781 payload hash checks, and
uploaded to `/data/pkg/wine-orbis-wow64-no-kernel32.pkg`. It ran successfully,
confirming the repair in the known-good split runtime.

The complete host PE runtime was then rebuilt at pinned Wine commit
`490f6d5dcbb2a5047345b8af88d114bbcaad69a8` with the corrected
`0613-wow64-avoid-kernel32-debug-helper.patch`. The clean build exposed a
malformed patch hunk and a diagnostic-string mismatch with the preceding
`0611` patch; correcting the hunk to replace the pinned source's `wow64: CPU
%s` `debugstr_w()` call made the patch series apply cleanly. The full PE build
completed at four jobs after eight jobs exceeded available RAM. The resulting
`x86_64-windows/wow64.dll` imports only `ntdll.dll`.

`ORBW00020` replaces all 1,598 matching i386/x86_64 PE files in the working
`ORBW00011` package stage with files from that rebuilt host runtime. It retains
the proven split EBOOT, PS4 `wowprospero.dll`, and PRXs, isolating the test to
the full PE set. All 1,781 staged payload hashes passed, and it was uploaded as
`/data/pkg/wine-orbis-full-pe-rebuilt.pkg`. Pinball ran on hardware for about
60 seconds; the latest report showed 29,861 frame submissions, 2,554 shown
frames, and 3,605 audible buffers, with no early stack overflow, signal, or
coredump. This confirms the complete rebuilt PE set works with the retained
split EBOOT and PRXs.

Future A/B packages should use `scripts/repackage-orbis-ab.py` with a known-good
complete `pkg-stage` and explicit `--replace REL=SOURCE` values. It refuses a
base stage without the two required platform PRXs and verifies every copied
payload file after packaging, preventing the omission in `ORBW00007/8`.
