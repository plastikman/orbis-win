# PS4 Mesa patches

Base: `mesa-build/mesa-ps4` commit `1a59cc147b54e3970814b37313e2f27357672e9d`.
Apply in filename order. 0001 preserves the Gladius detection change that was
already present in the ignored checkout before this session. 0002 implements
placed CPU aliases and reserve/unmap without changing the GPU VA. 0003 fixes
three defects in the ORBIS_DUMP_HUNG instrumentation: the dumper was a
process-wide one-shot that spent itself on a hang that recovered, the
fence-slot wait that the fatal hang actually takes never dumped at all, and the
user-data block stated a fill-overrun conclusion that its own dispatch grid
contradicts. 0004 changes Gladius's raster-config high half from the two-SE
shape to the four-SE shape and provides runtime overrides. The first hardware
run did not exercise that change: its command stream still wrote `0x2a00161a`.
The diagnostic follow-up with 0005 confirmed the Pro calculated and wrote
`0x3a00161a/0x2e` through the direct path, but the user still observed the same
cutscene crash. The raster-config change alone did not fix it. See
docs/HANDOFF-2026-10-09.md before changing the experiment.

0006 adds an opt-in, probe-process-only ACO hook: while
`ORBIS_PROBE_HW_ID=1`, the compute shader's `gl_SubgroupID` is emitted as
`s_getreg_b32 HW_REG_HW_ID` (GFX6–11 selector 4). The Gladius Probe uses that
value to atomically set one bit per observed `(SE, SH, CU)` tuple. The normal
subgroup-ID lowering path is unchanged when the variable is absent. The
instrumented package is `pkgout/probe/` and uploads to `/data/pkg/probe.pkg`.
Two independent Neo runs confirmed the same four-SE, 36-CU bitmap. RADV's
shader dump went to `stderr`, which this console discards. The updated probe
routes ACO assembly through `mesa_log_multiline` to `/data/probe-radv.log`;
retrieve only that known path with the no-login FTP getter. The accepted bitmap
was accompanied by `s_getreg_b32` reading `HW_REG_HW_ID`.

0007 lowers only the hard fence-slot wait deadline to 500 ms so the fatal
hang's label report and IB dump can run before Sony's roughly one-second HP3D
watchdog kills the title. The general wait-report cadence remains five seconds.
The first run confirmed the deadline fires at submission #19369 and identifies
stuck submission #19353, but its stream had been overwritten in the eight-slot
ring. 0008 retains 20 recent streams and limits each slot to 16K dwords (64 KiB),
with an explicit warning if a larger stream cannot be retained. The next run
captured fatal stream #20005 (1312 dwords) through the fence-slot path. This is
diagnostic instrumentation, not a GPU fix; see the handoff for findings.

0009 snapshots the PS/VS program bases at the last `DRAW_INDEX_2` before the CP
progress marker and dumps the first 128 dwords of each image when its address is
inside a live mapping. This avoids attributing a later draw's shader state to
the draw whose execution failed. The 15:49 run confirmed the fatal submit
remains bracketed at dwords 1080-1220 around the 4770-index draw at dword 1097.
It captured PS `0x883274300` and VS program `0x883238300`. The latter is RADV's
VS prolog: it returns to the main VS via `s_setpc_b64 s[2:3]`. Its target,
`0x883271a00`, is passed in user-data registers `0x4e/0x4f` and was not captured
by 0009. The exact PS bytes and prolog disassembly are retained under
`build-ps4-logs/`; read the VS dump only through its return at byte offset
`0x38`.

0010 captures the VS prolog input pointer and dumps the main VS body (resolving
either a direct code pointer or an upload-table pointer). It also checks whether
the indexed draw's index-buffer VA belongs to a live mapping. The fatal fence
slot wait bypassed the earlier stall scanner, so the next package adds 0011:
run the same capture on the fatal timeout path.

0012 extends the timeout capture with a bounded scan of the actual index data,
reporting min/max under both 16-bit and 32-bit interpretations plus the first
32 raw bytes. This separates a valid mapping from corrupt or out-of-range index
contents; the active index type remains a separate context register.

0013 logs the GPU topology RADV actually consumes from the PS4 kernel's
`device_info`: shader engines, arrays per engine, CU masks, and derived CU
counts. This directly compares the driver-reported topology with the hardware
ID probe's 4 x 9 measured topology.

0014 adds an opt-in Neo experiment for the measured sparse CU IDs. The
device bitmap reports `0x3ef` per Neo SE (IDs 0-3 and 5-9), while
`ORBIS_MEASURED_CU_MASK=1` applies it to `spi_cu_en`. Without the variable,
`spi_cu_en` keeps its normal all-ones default. Run the same package first with
the variable absent, then present, to test whether explicitly selecting the
measured sparse IDs changes the Neo hang. The experiment leaves the SE count,
active CU count, and raster configuration unchanged.

0015 adds an opt-in descriptor walk to the fatal fence-slot timeout. Set
`ORBIS_FOLLOW_HUNG=1` to inspect pointers from the retained fatal submission
only; this avoids the thousands of per-frame entries produced by the existing
full-submit `ORBIS_FOLLOW_SH` mode. The walk uses the existing live-mapping and
freed-range checks, and its normal 512-pointer cap applies to the fatal stream.
It is diagnostic only and requires rebuilding/reinstalling the app package.

The working checkout contains the patch series through 0026. Check the newest
with `git -C mesa-build/mesa-ps4 apply --check --reverse ../../src/mesa-patches-ps4/0015-follow-descriptors-on-fatal-hang.patch`.
The checkout is gitignored: these patches preserve its changes. Patch 0005 is
diagnostic only and does not change the raster-config values.

Build the archive using its Mesa development environment, then use
`./scripts/build.sh vkmapprobe --pkg --neo --dev-mesa` for the hardware test.
Host checks exercised the actual mapping functions with shared memfd-backed
views, including failed map/unmap/reservation calls; hardware validation is
required for GPU access and console coherency. Hardware passed GTT, visible VRAM and cached GTT: six GPU copies with zero
mismatches, reserve/remap and cleanup; `DONE tested=3 result=PASS`.

0016 adds an opt-in A/B for the recurring fatal `DRAW_INDEX_2`: with
`ORBIS_SHRINK_DRAW=1`, only packets with a 6144-index bound and exactly 4770
indices are logged and reduced to three indices (one triangle). The default
behavior is unchanged. The current Neo package was built with this patch and
uploaded; the matching runtime switch is enabled in `/data/prospero-win/radv.env`.
Install the uploaded package before launching so the setting reaches code that
contains the hook. A log line beginning `ORBIS_SHRINK_DRAW matched` proves the
experiment actually touched the target draw.

0017 extends the same opt-in predicate to the second failing draw identified by
0016's A run: 5961 indices at VA `0x88a278000`, with the same 6144-index bound.
It keeps the 4770-index target enabled as a control. The next run should log
both `ORBIS_SHRINK_DRAW matched` messages before we decide whether shrinking the
second draw changes the hang.

0018 adds the third draw observed before fatal submit #18504: 2760 indices with
a 4096-index allocation bound at VA `0x88a28b000`. With
`ORBIS_SHRINK_DRAW=1`, this exact draw is also reduced to three indices; the
4770- and 5961-index targets remain enabled. The previous 0017 run's RADV log
did not change during the follow-up launch, so it supplied no fresh GPU dump.
The 0018 Neo package at `/data/pkg/wine-app.pkg` was installed and tested;
SHA-256 `7d463e6e24504b7253fd8959f71d619a9131dde813ccb781b51a4cb811cdf4b3`.
All three `ORBIS_SHRINK_DRAW` targets matched, but submit #19482 still hung at
the same command-stream position. The next draw there was 2232 indices at IB
dword 392, with the same 4096-index bound. Stop adding exact counts to this
predicate: the experiment is moving the observed draw without moving the
failure. Continue from the fresh submit dump and inspect the shader/resource
state instead.

0019 adds a bounded live-mapping check for the first four V#-shaped base fields
in each user-data target during the fatal-only descriptor walk. It reports the
candidate base's current BO, offset and remaining bytes, or that it is outside
every live BO. This is explicitly candidate telemetry, not a descriptor-format
decode or a use-after-free verdict. It is enabled only with
`ORBIS_FOLLOW_HUNG=1` and caps output at 64 candidates per process. The
rebuilt Neo package is uploaded to `/data/pkg/wine-app.pkg`; SHA-256
`8c57ccef7fac0381d54760f190992c388275648f482e4c7d84dc870a494b6f01`. A
known-path no-login FTP RETR matched the local package byte-for-byte.

The 0019 run reproduced the hang at submit #18935. Its draw-bound pixel shader
loads an image-descriptor candidate from SH `0x00e` pointer `0x894600bc0` plus
`0x18`; the eight loaded dwords start `00000000 fffff1ff` and their common
image-base fields decode to `0xff0000000000`, outside live mappings. The log's
`gfx=9` is the raw enum ordinal for `GFX7` in this Mesa tree, not GFX9. The
descriptor's Vulkan binding and whether it caused the hang remain unknown.
The corresponding vertex range is valid in live BO31. This makes an invalid
sampled-image address a candidate, not a proven fault. The earlier suspected
`0x1fc004690000` address was a mistaken read of PM4 words, not the descriptor.
See the handoff before designing a descriptor mutation. The Orbis winsys
currently hardcodes IP version 7.2 in both title modes; that is a driver choice,
not a measurement of Gladius's Polaris-era feature set.

A repeat with the same package again hung at submit #18677 in forced base
identity mode. All three draw-shrink predicates matched, but the 2232-index
draw remained immediately before the stall. The SH `0x00e` pointer moved, but
the sampled-image bytes and decoded `0xff0000000000` base were identical to the
first run. Runtime reported `VK_ERROR_DEVICE_LOST`; see the handoff for capture
paths and the next descriptor-binding trace.

0022 widens 0021's sampled-image update trace from exactly byte offset `0x18`
to offsets in the first 256 bytes of each set, with a 256-entry cap per update
path. The first fatal run with 0021 emitted no trace records, although the
shader's set pointer still contained the suspicious `00000000 fffff1ff` words
at `+0x18`. The widened trace distinguishes a descriptor at another binding
offset from a descriptor region that was not updated through these Vulkan
paths. It is disabled unless `ORBIS_TRACE_GTA_DESC=1` is present.

0023 replaces the per-update cap in 0022 with a mutex-protected trace cache
keyed by set VA, binding, array element and byte offset. It logs every offset,
emits a descriptor only once per key (and again if its contents change), and
caps each path at 512 records. This addresses the 0022 capture, where 256
repeated low-offset template writes consumed the cap before the fatal set at
SH `0x00e` / BO60 offset `0x5c0` could be matched. The trace remains gated by
`ORBIS_TRACE_GTA_DESC=1`.

0024 adds an opt-in trace at descriptor-set bind time. With
`ORBIS_TRACE_GTA_SET=1`, RADV logs each unique bound set VA (up to 256), the
shader stage and descriptor-set SGPR, plus each binding's type, byte offset,
size and array length. This links the fatal SH user-data pointer to its actual
layout even when the descriptor-update-template trace has exhausted its cap.
It does not dump descriptor contents or modify descriptors.

0025 decodes the GFX7 image base from SQ image descriptor words 0 and 1 for
the recurring SH `0x00e` pointer and checks that address against RADV's live
BO mappings during a fatal dump. The generic V# candidate walker cannot answer
this because image descriptors store the base in 256-byte units and use a
different word layout. This distinguishes a bad image address from the earlier
misread of `fffff1ff` at byte offset `0x1c` as a base. It is diagnostic only;
it does not change descriptor contents or GPU state.

0026 adds `ORBIS_TRACE_GTA_IMAGE_OWNER=1`, a narrowly filtered trace for the
sampled-image descriptor pattern found at the fatal SH `0x00e` pointer. At
descriptor writes it records the destination set/binding, source `VkImageView`
and image, view/image formats and extents, sample count, bound image VA, mip
offset, decoded descriptor base and raw words. It covers ordinary descriptor
updates and update templates, and is capped at 32 matching entries per path.
Use it with 0024/0025 to determine whether the mapped descriptor base matches
the Vulkan image backing the bound view. It is diagnostic only.

0027 adds a fatal-only, opt-in dump of the full 288-byte descriptor set when
the pointer is in PS user-data register `0x00e` and binding 0 has the known
GTA image descriptor signature. Set `ORBIS_DUMP_GTA_SET=1` alongside
`ORBIS_FOLLOW_HUNG=1`; this emits all three 96-byte combined-image-sampler
bindings with a live-mapping check and an eight-set cap. The trigger is narrow
so it does not expand routine descriptor logging.

0028 logs the caller and requested size before `linear_alloc_child()` dereferences a null context. The 2026-10-19 Oblivion run faulted at `libvulkan.prx+0xffde23`, the first `ctx->offset` load in this helper, with `si_addr=0x4`; the package's matching link ELF resolves that instruction to `linear_alloc_child`. The trace keeps the fatal behavior unchanged and is intended to identify the caller in the next reproduction.

0029 adds the opt-in `ORBIS_WSI_FORCE_COPY=1` A/B. It bypasses registering the
application's linear swapchain images directly with VideoOut and instead uses
Mesa-owned scan-out buffers with the existing copy path. This isolates whether
zero-copy VideoOut ownership is involved when `vkAcquireNextImageKHR` stops
returning. Default behavior is unchanged. Package 10126 keeps
`ORBIS_WSI_NO_DEFER=1` from the preceding A/B and adds force-copy, so only the
zero-copy registration policy changes relative to that run. See
`docs/HANDOFF-2026-10-20.md` for the confirmed 10125/10126 traces and package.

0030 adds a one-shot warning when `vkAcquireNextImageKHR` has found no free image
for at least one second. It records the host/device busy-image bitmasks, swapchain
image count, direct-registration mode, app-owned deferred image, flip queue count,
and VideoOut pending-flip count. This distinguishes leaked app/device ownership
from a display flip queue that failed to retire. It is diagnostic only and does
not change acquire behavior. Package 10127 combines it with the 10126 forced-copy
A/B, so install that package for the next run.

0031 adds a startup marker identifying the WSI diagnostic build and logs the
first eight acquire entry/return pairs. This makes the next run prove both that
this PRX is active and whether `vkAcquireNextImageKHR` reaches WSI and returns.
The trace is bounded; later acquires are silent. It does not alter rendering or
synchronization.

0032 traces the common Vulkan acquire stages after the headless backend returns:
image callback, semaphore signal, fence signal, memory ownership, and common
return. It logs the first eight acquisitions and every acquisition from #1024
onward, so a late stuck call is bounded while showing exactly which stage did
not return. Patch 0031's startup marker confirms the diagnostic PRX is active.

On 2026-10-24, package 10129's trace reached acquisition #1995 and every
logged common stage returned `VK_SUCCESS`. This rules out acquire starvation
for the tested Titan Quest run. The post-freeze RADV budget had zero presents
and zero render passes/draws over 5.563 seconds while process CPU use remained
high, so the next diagnostic should locate why rendering/presentation stops
after successful acquisition rather than add more acquire tracing. See
`docs/HANDOFF-2026-10-20.md` for the full result and current next step.

0033 adds bounded `radv_queue_submit()` entry/return records to `/data/prospero-win/radv.log`. Each sampled record includes the submission number, command-buffer count, wait/signal counts, result, and whether it was an empty submission. The first 16 and every 120th submission are logged, with all failures logged. This distinguishes semaphore-only submits from game command buffers and shows whether RADV was entered and returned around the Titan Quest Create freeze. It does not alter queue behavior. Package 10163 combines this with the corrected Wine server `create_mapping` klog trace; install **Orbis Wine 10163 RADV Submit Trace** for the next run.

0034 logs every Orbis `radv_CreateGraphicsPipelines()` item at entry and return, including stage count/mask, create flags, result, and elapsed microseconds. An unmatched entry at the freeze identifies a call that did not return from RADV pipeline creation; continued returns mean the stall is earlier or later in the DXVK/game path. It changes no rendering behavior. Package 10165 retains the known-good 10153 wineserver PRX and includes both 0033 queue tracing and 0034 pipeline tracing. Install **Orbis Wine 10165 RADV Pipeline Trace** for the next Titan Quest Create reproduction.

0035 increases queue-submit trace density around the observed Titan Quest
freeze window: it records every radv_queue_submit() from #3001 through #4096,
in addition to the first 16, periodic samples, and failures. This closes the
gap left by 0033's every-120th sampling after #3000. An unmatched entry
identifies a submit stuck inside RADV; no entry after #3000 means execution
stopped above the queue boundary. Package 10166 includes 0033, 0034, and 0035.

0036 removes the submit-number windows for the follow-up test and logs every
RADV queue-submit entry and return from process startup. The 10166 trace showed
the same render stop at a different point than the 0035 window, so the full
trace avoids guessing a stable call number. Package 10167 includes 0033, 0034,
and 0036.

0037-0040 are the WSI hand-off and scaling changes and the acquire-trace cap;
their headers say what each does.

### Applying the series (read this before rebuilding the driver)

As of 2026-11-07, 0001-0040 apply only with `patch -p1 --forward` (fuzz), not
`git apply`, and 0010 loses one hunk in `ac_orbis_drm.c`. Delete the `.rej` and
`.orig` files and continue: 0041 restores what was lost. 0041 and 0042 then
apply with `git apply`. The whole series on `1a59cc1` reproduces
`mesa-build/mesa-ps4`, the tree that builds `libvulkan.prx`, byte-for-byte in
all 27 files. When the Mesa tree changes, add a patch here in the same commit,
so the series keeps matching what ships.

0041 is that resync. 0001-0040 had stopped rebuilding the driver that shipped
from 01.38 to 01.40: about 300 lines in 12 files were in no patch. It holds:
- the allocation-failure diagnostics from the GTA IV out-of-memory work and the
  1082 RADV allocation trace (`PW_ORBIS_VA_FAIL`, `PW_ORBIS_MAP_FAIL`,
  `PW_RADV_ALLOC_FAIL`, `RADV_GRAPHICS_PIPELINE_FAIL`, `RADV_CMD_OOM` and
  related);
- the Vulkan cursor overlay in `wsi_orbis.c`;
- 0010's lost hunk.

It changes no behaviour against shipped packages.

0042 stops the GPU address window filling up (2026-11-07, packages 01.40/01.41).
Fallout 3 (Pip-Boy), New Vegas (V.A.T.S.) and Left 4 Dead 2 (after 3.5 minutes)
all died when DXVK's next allocation failed:
- **Per-frame retire.** Freed VA ranges were handed back only when the GPU had
  caught up with every submission. Present waits for its own frame while the
  next one is submitted, so that almost never happened. The WSI's present now
  calls `ac_orbis_frame_boundary()`, which stamps parked ranges with the newest
  submission and releases them once the label passes. `PW_ORBIS_RETIRE` logs
  what is held.
- **Window extension.** The window is the arena plus `ORBIS_ARENA_EXT_MIB`
  (default 1024) of reserved addresses. Ranges there get their own direct
  memory when mapped (`PW_ORBIS_EXT`).
- **Honest heap sizes and budget.** The pool was advertised twice over
  (661 + 1322 MiB for a 992 MiB window) and its usage counted twice.

On 01.41 L4D2 ran 7 min 45 s with nothing left waiting, and Fallout 3, New
Vegas, GTA IV and Bloodlines passed. The same fix is offered to the driver's own
repository as [orbis-ports/mesa-ps4#1](https://github.com/orbis-ports/mesa-ps4/pull/1).

0043 keeps the hung-submit report from crashing the title (2026-11-08, 01.46).
Under heavy load the watchdog reports a submit as hung (four times in the 01.41
L4D2 run, harmlessly) and dumps the shaders that were running. One loop checked
only that a shader was inside the window, not that it was mapped; in L4D2 a VS
ended 256 bytes before an unmapped page, and the dump faulted inside
`vkQueueSubmit2`. It now skips a shader that is not fully mapped, as the draw
dump already did.
