# Upstream sync runbook (prospero-win → orbis-win/ps4-gladius)

How to bring a new upstream prospero-win / Wine generation into the PS4 port
without losing the port. Written after the ABI-v4 sync of 2026-11-04/05. That
sync built and packaged cleanly but shipped with no relocation, no Vulkan
surface, every game thread killed, broken signal masks, the wrong GPU driver,
no display and no controller. Each of those was a PS4 change that was already
solved and was silently dropped. Every gate below exists because it failed
once. Run them all, in order, before any console install.

The worked example is `docs/HANDOFF-2026-11-05.md`: GLDS10043 01.02 → 01.06,
where 01.06 runs GTA IV, FNV, FO3 and Oblivion native and MDK translated.

## 0. Principles

- **The port is additive.** A sync is a merge of two moving things: upstream,
  and our PS4 layer (patches, scripts, drivers, app, packaging). Every PS4
  change must end with a written disposition: *ported*, *superseded by named
  upstream code*, or *deliberately excluded*. Nothing may just disappear.
- **Check by content, never by number or filename.** Upstream and our archives
  reuse patch numbers for different patches. In this sync 40 numbers collided;
  that is how the Vulkan surface fix (0878) and the thread fix (0866) were lost.
- **Check binaries, not build logs.** A green build or a valid package proves
  nothing about behaviour. Gate on what is in the staged PRX/DLL/eboot (§5).
- **Change one thing per console cycle**, and only after the local gates pass.
  Keep the known-good baseline package installed under its own title ID.

## 1. Component map: where PS4 behaviour lives

| Component | Source | Built by | Ends up as |
|---|---|---|---|
| Wine Unix side (ntdll, win32u, wineserver, winevulkan, xinput…) | `<sync>/build/wine-ps5/source` + `src/wine-patches-ps4/` | `make -C build/wine-ps5/build <obj>`, then `scripts/prx-ps4.sh` | `sce_module/*.prx` and `win/wine/lib/wine/x86_64-unix/*.prx` (two copies; must match) |
| PRX export lists (descriptor) | **`scripts/prx-ps4.sh`** (our copy of upstream `tools/build_wine_ps5.sh` lists) | `scripts/prx-ps4.sh` | `prx/obj/<module>_desc.c` → PRX |
| Wine PE side (kernelbase, winevulkan.dll…) | `<sync>/source/.deps/wine-host/source` | `make -C .deps/wine-host/build <dll>`, then Wine's `tools/install -s` | `win/wine/lib/wine/{i386,x86_64}-windows/` |
| GPU driver (PS4 RADV) | `mesa-build/mesa-ps4` + `src/mesa-patches-ps4/` | `scripts/radv-prx-ps4.sh` | `libvulkan.prx` (both copies) |
| Relocation: eboot stub + app PRX | `src/reloc-wine-app/` (`stub.c`, `app_entry.c`, `stub-no-relro.ld`) + `src/prospero-win-patches-ps4/` | `scripts/build-relocatable-wine-ps4.sh` | `eboot.bin` (56 KB stub) + `sce_module/relocated_wine_app.prx` |
| Compat headers (signal numbers…) | `mesa-build/orbis-compat/include/` + `src/wine-platform-patches-ps4/` | compiled into every object that includes them | every PRX |
| Launcher / CPU selection | `native/wine64_main.c`, `native/pw_wine_prefix.c` | app PRX build | `relocated_wine_app.prx` |
| Profiles and prefixes | console `/data/prospero-win/profiles`, `/data/prospero-win/prefixes/<id>/system.reg` | by hand over FTP | runtime data, not in the package |

Two traps in this map:
- **Two Wine trees.** The Unix build tree and the wine-host PE tree must stay
  in sync. Apply every Wine patch to both, and `cmp` the touched files.
- **`scripts/prx-ps4.sh` is not a patch** but carries port-critical data: the
  PRX export lists. When upstream adds exports, this file must follow.

## 2. Freeze the baseline (before touching anything)

1. Record the known-good package: installer filename, SHA-256, title ID, and
   the complete `pkg-stage` path. Current baseline: GLDS10044 package 1090,
   `pkgout/falloutnv-no-relro-kept-data-1090/pkg-stage`.
2. Keep it installed under its own title ID. Test candidates under a separate
   title ID (GLDS10043) so the control is always one launch away.
3. Note what each control title proves:

   | Title | Proves |
   |---|---|
   | GTA IV | DXVK/Vulkan, threads |
   | FNV / FO3 | native WoW64, gameplay |
   | Oblivion | relocation at `0x400000`, RX image faults |
   | MDK | translator path, dgVoodoo D3D11 |

## 3. Content audit of every PS4 patch archive

Run the audit against the new trees: the Unix tree first, then the PE tree.

```sh
R=<sync dir>   # e.g. /home/zpeirce/codex_scratch/abi4-upstream-port-20261104
python3 scripts/audit-patch-presence.py src/wine-patches-ps4 \
    $R/build/wine-ps5/source $R/source/.deps/wine-host/source \
    --json $R/audit-wine.json
```

Every *absent* or *partial* **functional** patch is a worklist item. For each
one:
1. Dry-run it in order with its neighbours on a scratch copy
   (`patch -p1 --dry-run`). Later patches often depend on earlier ones (0862
   needs 0861).
2. If it applies, port it. Give it a **new number above the highest in both
   the upstream series and our archive** (this sync used 1036–1048), and apply
   it to both trees.
3. If it fails because upstream already does the same thing, record it as
   *superseded* and name the upstream code. In this sync: 0904 →
   `is_extended_key()`; 0740 → upstream `ps5drv_vulkan_cursor`, which showed
   up as a redefinition error.
4. *Partial* usually means upstream rewrote the feature. Read the missing
   lines before porting anything.

Diagnostic patches (trace/log/dump) can wait, with one exception: the 32-bit
`kernelbase.dll` `PW_EXCEPTION32` set (0962–0965, 0973, plus the fault-page
record from 1007) is required. Without it a guest crash leaves no context.

Repeat the audit for `src/prospero-win-patches-ps4/` against the synced
prospero-win source, and for `src/mesa-patches-ps4/` if Mesa moved.

## 4. Non-patch customizations: check each one explicitly

Each of these lives outside the patch archives and broke in this sync.

**Export lists.** Diff the `gen_prx_descriptor.py` argument lists in upstream
`tools/build_wine_ps5.sh` against `scripts/prx-ps4.sh`, for every module. Merge
upstream's new names. Keep our PS4 additions (`pw_wine_heap_calloc/realloc/
memalign`, `pw_wine_dl_*`, `pw_ps4_setenv`, `__wine_ps5_wait_for_exec_migration`).

*Missed in this sync:* the ABI-v4 per-index pad/menu calls (`pw_wine_pad_at`,
`pw_wine_set_pad_at`, `pw_wine_pads_wanted`, …), so the controller was lost.
`prx-ps4.sh` now adds sink exports automatically when `pw_wine_sink.c` defines
them. Check other modules the same way.

**GPU driver.** Use our RADV. Build it with
`PW_ROOT=<sync source> sh scripts/radv-prx-ps4.sh`, then confirm the linked
`libvulkan.shared.elf` has the same section and symbol sizes as the baseline's.

*Missed in this sync:* upstream's bundled driver was staged instead. It has
`orbis-drm` strings and none of ours (`PW_ORBIS_VA_FAIL`, `wsi/orbis …`).

**Relocation stub.** `eboot.bin` must be the ~56 KB no-RELRO stub that loads
`/app0/sce_module/relocated_wine_app.prx`. The stub/app contract (descriptor
version 1; exports `pw_relocated_wine_start` and
`pw_relocated_wine_release_eboot`) is ABI-independent, and the 1090 stub works
unchanged with the ABI-v4 app PRX.

*Missed in this sync:* the 749,760-byte full app was packaged as "the
relocatable EBOOT". It sits at `0x400000`, never loads the app PRX, and no
ABI-v4 run had relocated until 01.03. A stub package refused at launch
(`0x80020002`) was a packaging error, not a stub problem.

**Compat headers.** After any change to `orbis-compat` headers, rebuild
**every** object that includes them, not just the one being fixed. Find stale
objects like this:

```sh
H=mesa-build/orbis-compat/include/signal.h
for o in $(grep -oE 'dlls/[a-z0-9_/]+\.o|server/[a-z_0-9]+\.o' $R/build/wine-ps5/make.log | sort -u); do
  f=$R/build/wine-ps5/build/$o; [ -f $f ] || continue
  nm -u $f | grep -qE ' (pthread_sigmask|sigprocmask)$' && [ $f -ot $H ] && echo "STALE $o"
done
```

*Missed in this sync:* the FreeBSD signal-number fix rebuilt only
`signal_x86_64.o`. `server.o`, `thread.o` and the wineserver's `change.o`
still passed Linux `SIG_BLOCK=0`, which is invalid on the PS4, and
`SIG_SETMASK=2`, which the PS4 treats as `SIG_UNBLOCK`.

**Launcher CPU selection.** The launcher must select the CPU DLL explicitly
in **both** modes: `wow64native.dll` for native, `wowprospero.dll` for
translator.

*Open gap:* the ABI-v4 launcher only selects for native. Translator mode
falls back to the prefix's `Software\Microsoft\Wow64\x86` key, which a fresh
prefix sets to Wine's stock `wow64cpu.dll`. That backend cannot run on the
PS4 (MDK, 2026-11-05). Until the launcher is fixed, check that key in each
translator title's `system.reg`.

## 5. Build: the incremental, provable way

The full stage builders (`build-app-ps4.sh`, `build-relocatable-wine-ps4.sh`)
default to ABI-v3 unless `WOW64NATIVE_ABI=4` is set, and refuse any
`wow64native` pair whose hashes don't match the pins. Pass the current pair
with `WOW64NATIVE_DLL`, `WOW64NATIVE_ABI4_SHA256` and
`WOW64NATIVE_ABI4_PRX_SHA256`.

(`x86_64-windows/cpu.o` is not a runtime file. It is an intermediate object
that `tools/build_wow64native.sh`/`build_wowprospero.sh` compile next to their
DLL, and nothing loads it. A stage without it is not incomplete.)

`scripts/stage-provenance.py <stage> --root <build dir> …` maps every payload
file of a working stage to the build output that produced it. Use it to turn
a hand-assembled stage into a from-source recipe, as for CI.

For iterative sync work, start from the last complete stage and replace only
what changed, proving each change.

**Unix PRXs (ntdll, win32u, wineserver, …):**
1. Snapshot `$R/build/wine-ps5/prx` (`cp -a`).
2. Run a **no-change relink**: `PW_ROOT=$R/source sh scripts/prx-ps4.sh`. It
   must reproduce the snapshot's PRXs byte for byte. If it doesn't, find out
   why before changing anything.
3. Apply the patch to both trees, back up the touched files, and rebuild only
   the affected objects: `make -C $R/build/wine-ps5/build dlls/win32u/ps5drv.o …`.
4. Confirm the new code is really compiled in. Look for its strings in the
   `.o`; `#ifdef __PROSPERO__` arms can silently compile out.
5. Relink. Exactly the intended PRXs must differ from the snapshot.
6. Confirm the change is confined to the patched functions:
   ```sh
   sz(){ nm -S --defined-only "$1" | awk 'NF==4{print $4,$2}' | sort; }
   diff <(sz old/win32u.shared.elf) <(sz $R/build/wine-ps5/prx/win32u.shared.elf)
   ```
   Any unexpected function in that diff is a second, unplanned change
   (that's how the stale sigmask objects were found).

**PE DLLs (wine-host):**
1. Rebuild the single DLL:
   `make -C $R/source/.deps/wine-host/build dlls/kernelbase/i386-windows/kernelbase.dll`.
2. Strip it exactly as `make install` does:
   ```sh
   cd $R/source/.deps/wine-host/build && tools/install -m 644 -s \
     --strip-program="tools/winebuild/winebuild --builtin --strip-cmd=i686-w64-mingw32-strip" \
     -t <outdir> dlls/kernelbase/i386-windows/kernelbase.dll
   ```
   Compare section contents, not file hashes: file alignment can differ
   between strip runs, and both layouts load on hardware.
3. Check exports are unchanged (`objdump -p`).

Keep every pre-change object and ELF, the unstripped ELF/DLL for every changed
module, and the patch files beside the package (`<build>/symbols/`).

## 6. Assemble, gate, package

Assemble from the previous complete stage:

```sh
python3 scripts/repackage-orbis-ab.py \
  --base-stage <previous pkg-stage> --out-dir <new build dir> \
  --title-id GLDS10043 --title "<what changed>" --version 01.NN \
  --eboot-source pkgout/falloutnv-no-relro-kept-data-1090/pkg-stage/eboot.bin \
  --replace sce_module/ntdll.prx=<prx> \
  --replace win/wine/lib/wine/x86_64-unix/ntdll.prx=<prx>
```

The script skips the base stage's `eboot.bin` (so it can't override the
stub), verifies every payload hash, and passes `--version` to `make-pkg.sh`.

Package numbering:
- Candidates go to the test slot GLDS10043. GLDS10044 keeps the baseline
  until a build is deliberately promoted.
- Every build gets a new, increasing APP_VER (`01.NN`), so the console shows
  which build is installed before anyone reads a log.
- The GitHub workflow enforces this: `version` is required, or derived from a
  `vX.YY` tag.

From-source builds (and the GitHub runner) use
`scripts/ci/build-abi4-package.sh` instead of overlays. It runs the same
gates; see `scripts/ci/README.md`.

Then run all of these. None may be skipped:

```sh
# 1. Behaviour gates: exit status must be 0
python3 scripts/check-ps4-package-parity.py \
  pkgout/falloutnv-no-relro-kept-data-1090/pkg-stage <new>/pkg-stage \
  --elf-dir $R/build/wine-ps5/prx --upstream-root $R/source

# 2. Payload diff: must list only the intended files plus pkg.gp4 and param.sfo
diff -rq <previous>/pkg-stage <new>/pkg-stage | grep -vE '\.pkg|\.log'

# 3. Package signatures: all [OK]
ENV="LD_LIBRARY_PATH=/home/zpeirce/codex_scratch/libssl1.1/usr/lib/x86_64-linux-gnu \
DOTNET_BUNDLE_EXTRACT_BASE_DIR=/home/zpeirce/codex_scratch/dotnet-extract \
DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1"
env $ENV sdk/orbis-sdk-v1/sdk/bin/linux/PkgTool.Core pkg_validate <pkg>

# 4. Extract the built package and compare every payload with the stage
env $ENV sdk/orbis-sdk-v1/sdk/bin/linux/PkgTool.Core pkg_extract \
  --passcode 00000000000000000000000000000000 <pkg> <dir>
```

`check-ps4-package-parity.py` hard gates (each one failed in this sync):

| Gate | What it catches |
|---|---|
| Relocation | eboot is the stub; app PRX has the start/release contract and markers |
| Vulkan surface | win32u has the PS4 headless-surface arm (0878) |
| Display | win32u has `WINE_PS5_SCANOUT` (0861/0862) |
| Swapchain sizing | wsi_orbis fits any size (Mesa 0039) and win32u reports the window size (1054); both or neither |
| Quit to launcher | the app polls `pw_wineserver_guest_exit_pending` and wineserver exports it (1053) |
| GPU driver | `libvulkan.prx` is our PS4 RADV |
| Exports | ntdll/wineserver export upstream's lists and everything xinput looks up (read from the generated descriptor) |
| Diagnostics | i386 `kernelbase.dll` has `PW_EXCEPTION32` |
| Signals | no `pthread_sigmask`/`sigprocmask` call passes Linux `SIG_BLOCK=0` |
| Manifest | duplicate runtime copies match; no baseline payload is missing |

It also prints PS4-specific strings present in the baseline but missing from
the candidate. Each is a review item: usually a superseded diagnostic,
sometimes a lost fix.

## 7. Push and test on hardware

**Push.** Validated test-slot packages are uploaded without asking. Never
overwrite the baseline title.

```sh
python3 scripts/ftp-put.py 10.168.2.52 2121 <pkg> /data/pkg/IV0000-GLDS10043_00-GLDS100430000000.pkg
python3 scripts/ftp-get.py 10.168.2.52 2121 /data/pkg/IV0000-GLDS10043_00-GLDS100430000000.pkg <readback>
sha256sum <pkg> <readback>
```

Use only these minimal FTP scripts. A full FTP client (lftp) has crashed
GoldHEN.

**Check the log listeners before every test session:**
- **App log** (`ps5logd.py`, TCP 9300): appends to the active `ps5log-*.log`.
- **klog receiver** (`scripts/watch-klog.sh`): check the file's last-write
  time, not just the socket. A receiver can show `ESTABLISHED` while
  receiving nothing (10+ hours on 2026-11-05). If the klog is stale, kill only
  the `log-receiver.py` child; the loop reconnects it.
- **Coredump watcher** for the **test** title ID
  (`scripts/watch-coredump.py … GLDS10043`), pointed at the live klog file.

**Run one title, then confirm the session in this order.** If a step fails,
stop there; later results from that run are unattributable.

1. **Identity:** `PW_WINE64 build_marker=…`, and the console shows the expected
   APP_VER/title.
2. **Relocation:**
   - `PW_WINE64 relocatable eboot release status=0`
   - app module id like 1090's (`0x7f`)
   - **zero** `400000-… is "executable"` lines
3. **CPU mode:**
   - native: `cpu=native` + `wow64native initialized`
   - translator: `Loaded …wowprospero.dll` + `BTCpuSimulate simulate entry`. A
     `wow64cpu.dll` load means the prefix key is wrong (§4).
4. **Threads:** zero `wineserver: protocol error` lines in the klog session.
   `read: Bad file descriptor` here means every new thread is killed (0866).
5. **Vulkan:**
   - the client extension list includes `VK_KHR_win32_surface`
   - "Enabling N client instance extensions" lists all N names
   - the log reaches `win32u_vkCreateInstance` and `vkCreateDevice`
6. **Display and input:** confirm by eye, from the person at the console.
   - The sink counters stay at `shown=0`/`vk_shown=0` on the RADV direct-flip
     path even when the picture is fine.
   - `inputs=` is not a controller indicator either.

Test order used for ABI-v4: GTA IV (DXVK, threads, display), then FNV, FO3,
Oblivion, then MDK on the translator.

**Crashes:** follow `AGENTS.md`.
- Keep the `.sorbisdmp` for provenance only; it is encrypted.
- Read the fault from the klog (`ps4-pageflt-before … rip=… addr=…`) and from
  the in-process `PW_EXCEPTION_SETUP`/`PW_EXCEPTION32` records.
- Map the RIP to the module using the `+loaddll` base addresses, then use the
  matching unstripped build (`x86_64-w64-mingw32-objdump`/`nm` for PE,
  `llvm-addr2line` for ELF).
- Search the handoffs for the same signature before changing anything.
  MDK's native `GetStdHandle` → `fs:[0x18]` fault is a known open issue.

## 8. Failure catalog from the ABI-v4 sync

| Symptom on hardware | Evidence in the logs | Cause | Fix / gate |
|---|---|---|---|
| Every DXVK title returns to the launcher at startup | Client extension list lacks `VK_KHR_win32_surface`; "Enabling 4" prints 3 names; `DllMain …, 0, 1` | Archive 0878 lost to a number collision: `ps5drv` maps win32_surface only from `VK_KHR_display`, which PS4 RADV lacks | Series 1036; parity gate "Vulkan surface" |
| `0x400000` occupied, no release marker, Oblivion `c0000018` risk | `400000-4a4000 is "executable"`, no `relocatable eboot release` | Full app packaged as `eboot.bin` instead of the stub | `--eboot-source` = stub; parity gate "Relocation" |
| Hang on spinning dots; FNV hang | klog `wineserver: protocol error 00xx: read: Bad file descriptor` for each new thread | ntdll closes the request pipe the in-process server reads (archive 0866 lost) | Series 1044; check gate 4 in §7 |
| Odd hangs and garbage requests (`no memory for … request …`) | `pthread_sigmask(0, …)` / `(2, …)` in ntdll disassembly | Objects compiled before the FreeBSD signal header fix | Rebuild stale objects (§4); parity gate "Signals" |
| Hang inside a driver call | Thread stuck in `vkCreateComputePipelines` | Investigated as an RADV swap; the real cause was the thread deaths above | Use our RADV anyway; parity gate "GPU driver" |
| Game runs with audio but the screen is black | 3,000+ presents, nothing displayed | 0861/0862 (headless scanout, display-sized surface) and 0901/0902 missing | Series 1045–1048; parity gate "Display" |
| Controller dead | xinput finds no pad; display line `xinput=1` | `scripts/prx-ps4.sh` export list was ABI-v3 | Merge upstream export lists; parity gate "Exports" |
| Translator title crashes at once | `Loaded wow64cpu.dll`, AV loop in `wow64cpu`, stack overflow | Launcher defers to the prefix key in translator mode; the MDK prefix had `wow64cpu.dll` | Fix the prefix key; launcher fix still open (§4) |
| No crash context ("no `PW_EXCEPTION32`") | i386 kernelbase has 0 `PW_EXCEPTION32` strings | 0965/0973/1007 lost to number collisions | Series 1037–1043; parity gate "Diagnostics" |

## 9. Close out a sync

1. **Port series patches into the repo.** Copy every new series patch into
   the repo's patch directory under its series number, with the archive patch
   it came from noted in the commit message. The ABI-v4 series patches
   1036–1048 currently live in
   `<sync>/source/wine/patches/` and need promoting.
2. **Record dispositions.** For every absent/partial item from §3, write
   ported / superseded (with the upstream code) / excluded (with the reason).
   Store it with the audit JSON.
3. **Write the handoff:** package hash, installer filename, per-title results,
   open issues.
4. **Commit source, scripts and docs together.**
5. **Promote the baseline.** Only once the candidate passes the full control
   set may it replace the baseline title, and the old baseline stays archived.

## 10. Open items after ABI-v4 (2026-11-05)

- **Launcher translator CPU selection** (§4).
- **Still absent per the content audit:** networking (0979, 0988, 0989),
  Oblivion RX retries (0954–0956, though not needed in the 01.06 run), and
  core ntdll/wineserver fixes (0510, 0871, 0960, 1014, 1015). Some of the
  093x native-signal set may be superseded by the ABI-v4 wow64native design.
- **dxgi composition swapchain (0860):** applies cleanly but needs a
  wine-host PE build.
- **MDK native FS-base fault** (`HANDOFF-2026-11-03.md`, packages 1104–1108).
