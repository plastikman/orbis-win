# Fallout: New Vegas on PS4 — diagnostic review brief (2026-11-02)

This brief is for comparing the PS4-native failures with the other PS4 porting
work. It records observations and open questions; it does not claim one root
cause for the different faults.

## Platform and tested package

- Hardware: PS4 custom AMD APU; the runtime GPU driver is Mesa RADV. The
  captured screen reports Mesa `26.3.0-devel`.
- CPU mode: native WoW64, confirmed in the Wine profile trace.
- Package marker: 1086; installer:
  `IV0000-GLDS10044_00-GLDS100440000000.pkg`.
- Package SHA-256:
  `edc8a4860e87769e8e470f3d7548e25a02f439d87f0980d23c3fa67e4d8b044c`.
- Exact `FalloutNV.exe` SHA-256:
  `a50c0e91b5d729ef10a921c32aa0cc20aac5366630056d1d60c669917a936fbb`.
  It was loaded at `0x00400000`.
- The package preserves the relocation, input, filesystem, close-path, native
  CPU and existing memory fixes. Its only code change from package 1085 is a
  bounded wineserver thread-ID to host-LWPID diagnostic.

## Latest run: gameplay fault after video stopped

The first recorded fault is an in-process 32-bit guest read AV:

```text
PW_EXCEPTION32 tid=0090 eip=00ec6db0 esp=1876f3d8 ebp=1876f3e8
  eax=1876f478 ebx=200006e8 ecx=1876f478 edx=00000000 esi=1525d8a0 edi=00000000
PW_EXCEPTION32 pc-bytes eip=00ec6db0 bytes=8 words=013a028b,c00a2e75
PW_EXCEPTION32 frame depth=0 ... return=0066641d
PW_EXCEPTION32 frame depth=1 ... return=006ec9c9
PW_EXCEPTION32 frame depth=2 ... return=006ec85f
PW_EXCEPTION32 frame depth=3 ... return=0044955d
```

Exact PE disassembly at `FalloutNV.exe+0x00ac6db0` is `mov eax,[edx]`, followed
by byte comparisons. The comparison helper's caller at `0x004496d0` passed a
null first string pointer and a valid stack string pointer. The crash is
therefore a game-side null dereference in a string-compare path; the registers
do not yet tell us why the caller supplied null or whether that path should
allow null.

The fault-time object pointer `0x1525d8a0` was readable when sampled. Its
first four DWORDs were `1d08caa0, 16262db0, 00000000, 16261720`; its vtable
was nonzero. The stack trace does not prove that this object caused the null
argument.

Two guest reads immediately beforehand were caught and retried by the existing
recent-migration path:

```text
si_addr=15258e30 rip=66635a ...
map-fault-probe ... addr=15258e30 ... range=15258000-1525c000 kprot=0x3 result=kernel-allows
exec-migrate-late-retry ... addr=15258e30 ... prot=0x3
si_addr=16261728 rip=a5be35 ...
map-fault-probe ... addr=16261728 ... range=16260000-16264000 kprot=0x3 result=kernel-allows
exec-migrate-late-retry ... addr=16261728 ... prot=0x3
```

The second address is eight bytes into the pointer `0x16261720` in the object
snapshot. Both retries continued. This timing makes memory migration a lead to
check, not an established cause of the later null string pointer.

### Graphics and memory around the fault

The PS4 log records selected `vkQueuePresentKHR` results of `0` through present
#2040, before the guest exception. `VK_ERROR_SURFACE_LOST_KHR` appears after
the process is already unwinding. No earlier device-lost or surface-lost error
was found in this captured window. This makes a RADV submit failure an
unsupported explanation for the first fault; it does not rule out a resource
or memory-management bug that later corrupts game state.

Flexible memory fell from about 100 MiB to 26 MiB during the preceding
35 seconds. The sample had `dmem_failures=0`, and there is no explicit
DXVK/RADV allocation-failure record in the fatal window. Treat that as
low-ish headroom, not proof that memory is irrelevant.

### Earlier distinct FNV failures

Do not merge these into one signature:

- Package 1081, gameplay: null-vtable read at runtime EIP `0x00a59d5e`.
  About nine seconds earlier DXVK failed to allocate an 83,755,016-byte
  D3D9 depth/stencil image (`D24S8` mapped to `D32_SFLOAT_S8_UINT`) and logged
  that the texture had no backing storage. Flexible memory was 3 MiB. The
  temporal relation is strong, but the logs do not prove the failed image
  created the bad game object.
- Package 1079, V.A.T.S.: separate D3D9 null-object failure, documented in
  `docs/HANDOFF-2026-11-02.md` under the allocation trace.
- Package 1027: other null read and null write sites. They are not the same
  instruction or stack as the 1086 string compare.

The 1081 memory-allocation failure is direct evidence that the PS4 AMD/RADV
allocation path has failed for FNV. The 1086 record is instead a guest CPU
fault after successful present calls. They may share an underlying memory
problem, but that link is not measured yet.

## Cross-project work to compare

Max's latest commit,
[187fa1d4](https://github.com/Maxikozie/ps4-wine/commit/187fa1d4fa4a66820e466ea98b7ac00466034e65),
reports milestone i1 passing on a PS4 Slim: release of the low `0x400000`
EBOOT range, PRX survival, and a 600-second run. The commit also advances the
`prospero-win` submodule reference. This is useful shared progress, although
i1 itself is a low-base/PRX lifetime probe rather than an FNV gameplay test.

The useful FNV-adjacent work is in Max's earlier `g1m` commits, not the new
i1 low-base release itself. Commit
[`7871ec3`](https://github.com/Maxikozie/ps4-wine/commit/7871ec3) records
`g1m`, `g1`, and `e` passing after Mesa patch 0003 made RADV advertise
`VK_EXT_map_memory_placed` on PS4. The documented test used a 32-bit Vulkan
probe (`vk32.exe`), then a 32-bit DXVK D3D9 triangle and Bloodlines. The patch
[0003](https://github.com/Maxikozie/ps4-wine/blob/d6e290c2dcc1ca08bd654219a3a8ab58f30a3bd/patches/mesa-ps4/0003-orbis-placed-map-cpu-alias.patch)
maps AMD BO pages as CPU aliases at requested low addresses. This is direct
evidence for the 32-bit Vulkan/DXVK mapping mechanism.

Our repo already has the corresponding PS4 RADV implementation in
`src/mesa-patches-ps4/0002-orbis-placed-cpu-alias.patch`. Its hardware tests
are recorded in `docs/PS4-MESA-CROSS-TEST-RESULTS.md`: low aliases, reservation
restore/remap, and GPU copies across GTT, visible VRAM, and cached GTT passed
with zero mismatches. These are converging implementations of the same
capability, though their alias protections/lifecycle should be compared before
porting code between them.

This work could help explain the earlier 32-bit `vkMapMemory` refusal and
missing D3D9 resources. It does not directly explain the 1086 null string read.
The 1081 FNV run's large image allocation failure also needs separate
end-to-end evidence before attributing it to placed mapping. Check whether the
exact FNV package/runtime reports the placed-map capability and records alias
map/unmap failures or live bytes during the failure.

Relevant local implementation history:

- `docs/HANDOFF-2026-11-02.md`: packages 1027, 1079, 1081, 1082, 1085 and 1086.
- `docs/HANDOFF-2026-10-26.md`: prior FNV null-object and memory-map findings.
- Package 1086 app log:
  `/home/zpeirce/codex_scratch/fnv-native-thread-map-1086/app-run-20261102-1651-to-1653.log`
  (SHA-256 `13332449b84bbe78c6356a4be4e7fab7ef3531e3db1fe53784392c1a5b928e4f`).
- Package 1086 klog:
  `/home/zpeirce/codex_scratch/fnv-native-thread-map-1086/klog-receiver-20261102-1651-to-1654.log`
  (SHA-256 `252a3aaa7d499289cc3d298b3d1985ebd37a5fcfa105dd22218de17aebaf71b1`).
- The complete raw logs remain in local scratch rather than this repository;
  this committed brief preserves the relevant excerpts and identifiers.
- No `.sorbisdmp` was retrieved. The investigation uses Wine's in-process
  `PW_EXCEPTION32` diagnostics; the dump is not needed to reproduce these
  records.

## Questions for independent review

1. Does the caller at `0x004496d0` intentionally allow its first string
   argument to be null, or does the call chain show a bad game object/state?
2. Can the recent-migration retries at `0x15258e30` and `0x16261728` affect
   the values subsequently read by the object/comparison path? What evidence
   would distinguish a retry/mapping defect from normal lazy-page faults?
3. Since both repositories have a tested placed CPU-alias path, what differs
   between their RADV lifecycle/protection handling, and does the exact FNV
   runtime exercise it? Which capability, alias/unmap counters, and requested
   guest addresses would show whether it participates in the FNV failure?
4. For the 1081 D3D9 allocation failure, can the per-memory-type `VkResult`,
   BO/VA map result, and failed-image lifetime be traced end-to-end to see
   whether an unavailable texture is later treated as a valid game object?
5. What single bounded diagnostic would answer one of these questions on the
   next run without adding a broad log flood or changing the runtime behavior?

## Upstream DXVK context

DXVK reports #4840 and #4851 concern FNV on recent discrete Radeon cards using
the proprietary Windows AMD driver. They are useful as AMD/FNV context, but
they do not reproduce on the PS4's custom AMD APU with Mesa RADV and do not
match this guest-code fault:
[#4840](https://github.com/doitsujin/dxvk/issues/4840),
[#4851](https://github.com/doitsujin/dxvk/issues/4851). No matching PS4/RADV
report for the 1086 null string read was found in the searched DXVK issues.
