# Project notes for Codex

- **Upstream syncs** (new prospero-win / Wine generation) follow
  `docs/UPSTREAM-SYNC-PLAYBOOK.md`. Audit PS4 patches by content with
  `scripts/audit-patch-presence.py`, never by patch number: upstream reuses
  numbers. Do not install any package until
  `scripts/check-ps4-package-parity.py <1090 stage> <candidate stage> --elf-dir
  <prx build dir> --upstream-root <source>` exits 0.

- PS4 `.sorbisdmp` crash dumps must be analyzed with the local dump/debugging
  tools available on this workstation. Do not conclude that a dump is
  undecodable based only on its `FACECS` header, `file` output, or readable
  strings. Find and run the existing decoder/debugger workflow, then symbolize
  the result against the exact package binaries and symbols.
- **What the `.sorbisdmp` container actually is** (measured 2026-10-28 on
  `GLDS10085_1793220239.sorbisdmp`, 306,514 B, so do not re-derive this):
  64-byte plaintext header — `00 00` then ASCII `FACECS` at offset 2, a u64
  version/count of 2, then a two-entry table of u64 (offset, size) pairs
  (`0x130`/`0x4AB12` and `0x130`/`0x4AA32`) — followed by a body from offset
  `0x58` that is **encrypted**. Measured, not assumed: Shannon entropy
  **7.9994 bits/byte**, all 256 byte values present, 0.42% zero bytes (random
  is ~0.39%), and only 74 ASCII runs of >=8 chars in 306 KB where a readable
  core dump would carry hundreds of module paths and symbol names. Nothing
  decompresses as raw-deflate, zlib or gzip at any offset in the first 32 KiB.
  This matches fail0verflow's note that PS4 crash dumps are encrypted from
  roughly firmware 4.50 onward
  (https://fail0verflow.com/blog/2017/ps4-crashdump-dump/,
  https://www.psdevwiki.com/ps4/COREDMP).
- **There is no local decryptor and the public one does not apply.**
  SocraticBliss's `ps4_crash_dump_decryptor.py`
  (https://gist.github.com/SocraticBliss/b787fc8f6685f0d72beabccf8af48062)
  decrypts a *different* artifact — `orbiscore-systemcrash.orbisstate`, whose
  body starts at `0x4000` under AES-CBC — and it needs AES + HMAC keys derived
  from per-console sealed keys (`getSealedKeySecret`, 5.05-era) that are not
  published and are not on this workstation. The SDK ships `libSceCoredump.so`
  (a *writer* library) and only `create-fself`, `create-gp4`, `PkgTool.Core`
  and `readoelf` as executables; none read a dump. So: retain dumps for
  provenance, but **do not plan an investigation around decrypting one.**
- **Use the in-process diagnostics instead — that is what "decoded" has always
  meant here.** `dlls/kernelbase/debug.c` carries `log_exception_context32()`
  under `#ifdef __i386__`, which emits the records that actually answer a guest
  fault, e.g.
  `PW_EXCEPTION32 tid=0090 eip=00a3368c esp=... eax=... ecx=23326f30 ...`,
  plus `PW_EXCEPTION32 stack words=...`, `pc-page` and `pc-bytes`. In the
  11:20 2026-10-28 run `ecx` held the exact faulting pointer. These come from
  `src/wine-patches-ps4/0962`-`0965` and `0973`, they compile only into the
  **32-bit** `kernelbase.dll`, and that DLL is supplied to the packager through
  the `PS4_KERNELBASE32_DLL` input of `scripts/build-relocatable-wine-ps4.sh`.
  The `kernelbase.dll` in `win/wine/lib/wine/i386-windows/` of the ordinary
  build contains **zero** `PW_EXCEPTION32` strings, so a default build has no
  guest-fault diagnostics at all. **Before investigating any guest fault,
  confirm `strings <pkg>/win/wine/lib/wine/i386-windows/kernelbase.dll | grep -c
  PW_EXCEPTION32` is nonzero**; if it is zero, rebuild that DLL and pass it via
  `PS4_KERNELBASE32_DLL` rather than inferring the fault from klog.
- Reuse the established crash workflow; do not rediscover it on every run:
  arm `scripts/watch-coredump.py HOST 2121 KLOG OUT_DIR TITLE_ID` against the
  active appended klog before launch (GoldHEN deletes dumps shortly after
  reporting them), then retain the retrieved `.sorbisdmp`, matching klog
  window, package hash/build marker, and exact runtime symbols together under
  `/home/zpeirce/codex_scratch/<title>-coredumps/`. For Wine guest faults, use
  the first-exception register/context and bounded guest-stack/object records
  emitted by the PS4 Wine diagnostics, correlate their timestamp with klog,
  then map the guest EIP/RVA against the exact game PE and map PRX PCs against
  the exact loaded module plus its matching `.shared.elf`. Use
  `x86_64-w64-mingw32-objdump -d` for PE disassembly and
  `llvm-addr2line -e <matching-unstripped-elf> <module-relative-address>` for
  ELF symbols. Distinguish guest CPU faults from SCE async/GPU suspend-timeout
  exceptions: the latter explicitly have no thread context, so they do not
  identify a guest CPU fault or prove which guest instruction failed. If they
  coincide with a user action, correlate GPU/submit logs before dismissing the
  action; a stalled render submission may still be relevant. Check the handoff
  for an identical signature before proposing another run.
- Preserve crash dumps and record their path, title ID, package/build marker,
  selected CPU mode, and matching symbols before analysis.
- Before investigating a new crash, search earlier runs, handoffs, and logs for
  the same signature and reuse those findings instead of repeating ruled-out
  experiments.
- When bringing up a new game, prefer controlled A/B runs against a known
  baseline, changing one relevant variable at a time where practical.
- Build relocatable packages by default and keep the relocation fix in every
  test package. Do not create or upload a nonrelocatable package unless the
  user explicitly asks for that comparison.
- When telling the user which package to install, give the exact installer
  filename (for example, `IV0000-GLDS10085_00-GLDS100850000000.pkg`). Keep this
  filename consistent across builds for the same title ID; use the friendly
  title/build marker only as extra context, never as a substitute for the
  installer filename.
- Keep project changes additive: preserve known-good fixes and behavior in
  each new package (including relocation, input, filesystem, and close-path
  fixes). Before packaging, compare the candidate against the latest known-good
  baseline and account for every omitted or changed fix. Remove a fix only for
  an explicitly scoped A/B test, and restore it in the next package.
- Do not use `/tmp` for project artifacts; use `/home/zpeirce/codex_scratch`.
- Fallout New Vegas gameplay testing should default to the native WoW64 CPU
  backend. Do not ask the user to repeat translator runs unless a specific,
  controlled A/B is necessary to distinguish a native-only regression.
- For CPU-mode A/Bs, `PW_WINE64 cpu=translator` only proves the profile request.
  Confirm the active translator from the Wine trace: it must load
  `wowprospero.dll` and reach the `BTCpuSimulate` / `simulate entry` marker.
  Check the prefix's `Software\\Microsoft\\Wow64\\x86` registration as well;
  a profile that merely omits the native override can inherit `wow64cpu.dll`
  and never run the prospero-win translator. Keep the launcher selecting the
  requested CPU DLL explicitly for both modes.
